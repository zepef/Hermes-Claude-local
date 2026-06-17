# Claude Opus Proxy — Manuel d'Installation

## Principe

Ce proxy expose un endpoint OpenAI-compatible (`/v1/chat/completions`) qui transmet les requêtes à `claude -p` via le CLI. Il permet d'utiliser Opus dans Hermes (MiniMax Code) en passant par ton abonnement Max Pro, sans API key.

**Limitations :**
- Chaque requête lance un nouveau processus `claude` → latence ~5-10s par requête
- Pas de session persistante ni de cache de contexte entre appels
- Hermes doit tourner sur le même Windows que le proxy (localhost)

---

## Prérequis

- Windows avec Node.js installé (`node --version` fonctionne)
- Claude CLI installé (`claude --version` fonctionne)
- Compte Claude Max Pro connecté sur le CLI (`claude -p "hi" --output-format json` fonctionne)
- Hermes / MiniMax Code installé

---

## Installation

### 1. Installer le package `@ai-sdk/openai`

```powershell
npm install -g @ai-sdk/openai
```

### 2. Créer le fichier `server.js`

Colle le contenu suivant dans `%USERPROFILE%\.claude\claude-opus-proxy\server.js` :

```js
// claude-opus-proxy — OpenAI-compatible proxy for claude -p
const http = require('http');
const { spawn } = require('child_process');
const os = require('os');
const fs = require('fs');
const path = require('path');

const PORT = process.argv[2] || 8080;
const MODEL = process.argv[3] || 'claude-opus';
const IS_WIN = process.platform === 'win32';
const WORKSPACE = process.env.CLAUDE_WORKSPACE || (IS_WIN ? require('os').homedir() : '/home/user');

function buildPrompt(messages) {
  const parts = [];
  for (const msg of messages) {
    const role = msg.role === 'user' ? 'Human' : msg.role === 'assistant' ? 'Assistant' : msg.role === 'system' ? 'System' : msg.role;
    const content = typeof msg.content === 'string' ? msg.content : JSON.stringify(msg.content);
    if (role === 'System') {
      parts.push(`<system>\n${content}\n</system>`);
    } else {
      parts.push(`<${role}>\n${content}\n</${role}>`);
    }
  }
  return parts.join('\n\n');
}

function callClaude(prompt, model) {
  return new Promise((resolve, reject) => {
    const tmpDir = os.tmpdir();
    const promptFile = path.join(tmpDir, 'claude-prompt-' + process.pid + '.txt');
    fs.writeFileSync(promptFile, prompt, 'utf8');

    let stdout = '';
    let stderr = '';
    let child;

    if (IS_WIN) {
      const scriptFile = path.join(tmpDir, 'claude-call-' + process.pid + '.ps1');
      const psScript = `
$ErrorActionPreference = 'Stop'
try {
    $content = Get-Content -Path '${promptFile.replace(/\\\\/g, '\\\\\\\\')}' -Raw -Encoding UTF8
    $env:CLAUDE_MODEL = '${model}'
    $result = $content | claude -p --output-format json 2>&1
    Remove-Item '${promptFile.replace(/\\\\/g, '\\\\\\\\')}' -Force -ErrorAction SilentlyContinue
    Remove-Item '${scriptFile.replace(/\\\\/g, '\\\\\\\\')}' -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0) { throw $result }
    Write-Output $result
} catch {
    Remove-Item '${promptFile.replace(/\\\\/g, '\\\\\\\\')}' -Force -ErrorAction SilentlyContinue
    Remove-Item '${scriptFile.replace(/\\\\/g, '\\\\\\\\')}' -Force -ErrorAction SilentlyContinue
    Write-Error $_.Exception.Message
    exit 1
}
`;
      fs.writeFileSync(scriptFile, psScript, 'utf8');
      child = spawn('powershell.exe', ['-ExecutionPolicy', 'Bypass', '-NoProfile', '-File', scriptFile], {
        cwd: WORKSPACE,
        windowsHide: true,
        env: { ...process.env, CLAUDE_PROJECT_DIR: WORKSPACE },
      });
    } else {
      const scriptFile = path.join(tmpDir, 'claude-call-' + process.pid + '.sh');
      const shScript = `#!/bin/bash
set -e
export CLAUDE_MODEL="${model}"
PROMPT=$(cat "${promptFile}")
echo "$PROMPT" | claude -p --output-format json
rm -f "${promptFile}" "${scriptFile}"
`;
      fs.writeFileSync(scriptFile, shScript, 'utf8');
      fs.chmodSync(scriptFile, 0o755);
      child = spawn('bash', [scriptFile], { cwd: WORKSPACE, env: { ...process.env } });
    }

    child.stdout.on('data', (data) => { stdout += data.toString(); });
    child.stderr.on('data', (data) => { stderr += data.toString(); });
    child.on('error', reject);
    child.on('close', (code) => {
      fs.unlink(promptFile, () => {});
      if (code !== 0) { reject(new Error(`claude exited with code ${code}: ${stderr}`)); return; }
      try { resolve(JSON.parse(stdout)); }
      catch (e) { reject(new Error(`Failed to parse: ${stdout.slice(0, 200)}`)); }
    });
  });
}

const server = http.createServer(async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  const url = new URL(req.url, `http://localhost:${PORT}`);

  if (req.method === 'GET' && (url.pathname === '/v1/models' || url.pathname === '/models')) {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ object: 'list', data: [{ id: `claude-${MODEL}`, object: 'model', created: 0, owned_by: 'claude-code-cli' }] }));
    return;
  }

  if (req.method === 'POST' && url.pathname === '/v1/chat/completions') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', async () => {
      try {
        const payload = JSON.parse(body);
        const messages = payload.messages || [];
        const model = payload.model || MODEL;
        const stream = payload.stream !== false;

        const prompt = buildPrompt(messages);
        const claudeModel = model === 'claude-opus' ? 'opus' : model;
        const result = await callClaude(prompt, claudeModel);

        const completionId = `chatcmpl-${Date.now()}`;
        const created = Math.floor(Date.now() / 1000);
        const text = typeof result.result === 'string' ? result.result : JSON.stringify(result.result);

        if (stream) {
          res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive', 'X-Accel-Buffering': 'no' });
          res.write(`data: ${JSON.stringify({ id: completionId, object: 'chat.completion.chunk', created, model: MODEL, choices: [{ index: 0, delta: { content: text }, finish_reason: null }] })}\n\n`);
          res.write(`data: ${JSON.stringify({ id: completionId, object: 'chat.completion.chunk', created, model: MODEL, choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] })}\n\n`);
          res.write('data: [DONE]\n\n');
          res.end();
        } else {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ id: completionId, object: 'chat.completion', created, model: MODEL, choices: [{ index: 0, message: { role: 'assistant', content: text }, finish_reason: 'stop' }], usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 } }));
        }
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: { message: err.message, type: 'internal_error' } }));
      }
    });
    return;
  }
  res.writeHead(404); res.end();
});

server.listen(PORT, () => {
  console.log(`Claude Opus proxy running at http://localhost:${PORT}`);
  console.log(`Model: ${MODEL} (alias -> claude-opus-4-8)`);
});
```

**Important :** remplace `C:\\Users\\<TON_USER>` par ton vrai chemin utilisateur.

### 3. Créer le script de démarrage `start-proxy.ps1`

Colle le contenu suivant dans `%USERPROFILE%\.claude\claude-opus-proxy\start-proxy.ps1` :

```powershell
$ProxyDir = "$env:USERPROFILE\.claude\claude-opus-proxy"
$Port = 8080

$existing = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Port $Port already in use - killing old process"
    Stop-Process -Id $existing.OwningProcess -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

Write-Host "Starting Claude Opus proxy on http://localhost:8080"
Write-Host "Model: opus (claude-opus-4-8)"
Write-Host ""

$proc = Start-Process -FilePath "node" -ArgumentList "$ProxyDir\server.js","8080","claude-opus" -WindowStyle Hidden -PassThru
Write-Host "PID: $($proc.Id)"
Write-Host ""
Write-Host "GET  http://localhost:8080/v1/models"
Write-Host "POST http://localhost:8080/v1/chat/completions"
```

---

## Configuration de Hermes / MiniMax Code

### Ajouter le provider custom

1. Ouvre Hermes → *Settings* → *Providers* ou *Model Configuration*
2. Ajoute un nouveau provider de type *OpenAI Compatible* / *Custom*
3. Configure :
   - **Base URL** : `http://localhost:8080/v1`
   - **API Key** : n'importe quoi (ex: `not-needed`)
4. Sauvegarde

### Activer le provider

1. Relance Hermes complètement
2. Dans le sélecteur de modèle, choisis `claude-code-cli` → `claude-opus`
3. C'est parti

---

## Utilisation

### Démarrer le proxy (à faire avant chaque session Hermes)

```powershell
powershell -File "$env:USERPROFILE\.claude\claude-opus-proxy\start-proxy.ps1"
```

### Vérifier que ça marche

```powershell
Invoke-WebRequest -Uri "http://localhost:8080/v1/models" -Method GET
# doit renvoyer : {"object":"list","data":[{"id":"claude-opus",...}]}
```

---

## Dépannage

| Erreur | Cause | Solution |
|---|---|---|
| `ENAMETOOLONG` | Prompt trop long pour la ligne de commande | Le script utilise déjà un fichier temporaire — vérifie que tu as la dernière version |
| `model: not found` | Mauvais nom de modèle | Le proxy traduit automatiquement `claude-opus` → `opus` |
| Provider non visible dans Hermes | Proxy pas encore découvert | Relance Hermes après le démarrage du proxy |
| Timeout (~30s) | `claude` met trop longtemps à démarrer | Première requête toujours lente (~10s), les suivantes ~3-5s |
| `claude exited with code 1` | Erreur dans `claude -p` | Lance `claude -p "test" --model opus --output-format json` en PowerShell direct pour voir l'erreur |

---

## Architecture

```
Hermes (MiniMax Code)
  POST /v1/chat/completions
  model: claude-opus
       |
       v
Claude Opus Proxy (Node.js)
  - Traduit claude-opus -> opus
  - Écrit prompt dans fichier temp
  - Lance powershell.exe / bash
       |
       v
claude -p --model opus --output-format json
  (via ton abonnement Max Pro OAuth)
       |
       v
Réponse JSON -> proxy -> SSE stream -> Hermes
```

