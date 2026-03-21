const editor = document.getElementById('editor');
const errorEl = document.getElementById('error-message');
const successEl = document.getElementById('success-message');
const listEl = document.getElementById('server-list');
const editorPanel = document.getElementById('editor-panel');
const toggleArrow = document.getElementById('toggle-arrow');

function getTauri() {
  return window.__TAURI__;
}

async function invoke(cmd, args) {
  const tauri = getTauri();
  if (!tauri || !tauri.core) throw new Error('Tauri not ready');
  return tauri.core.invoke(cmd, args);
}

// Bind events
document.getElementById('save-btn').addEventListener('click', saveConfig);
document.getElementById('editor-toggle').addEventListener('click', toggleEditor);

// Cmd+S / Ctrl+S to save
document.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === 's') {
    e.preventDefault();
    saveConfig();
  }
});

// Tab key for indentation
editor.addEventListener('keydown', (e) => {
  if (e.key === 'Tab') {
    e.preventDefault();
    const start = editor.selectionStart;
    const end = editor.selectionEnd;
    editor.value = editor.value.substring(0, start) + '  ' + editor.value.substring(end);
    editor.selectionStart = editor.selectionEnd = start + 2;
  }
});

// Toggle click on server list rows (event delegation)
listEl.addEventListener('click', (e) => {
  const toggle = e.target.closest('[data-action="toggle"]');
  if (!toggle) return;
  const name = toggle.dataset.name;
  const enabled = toggle.checked;
  toggleServer(name, enabled);
});

// Load on startup
document.addEventListener('DOMContentLoaded', () => {
  function tryLoad() {
    if (getTauri() && getTauri().core) {
      loadConfig();
      loadServers();
    } else {
      setTimeout(tryLoad, 50);
    }
  }
  tryLoad();
});

function toggleEditor() {
  const hidden = editorPanel.classList.toggle('hidden');
  toggleArrow.textContent = hidden ? '\u25B6' : '\u25BC';
}

async function loadConfig() {
  try {
    const json = await invoke('get_config_json');
    try {
      const parsed = JSON.parse(json);
      editor.value = JSON.stringify(parsed, null, 2);
    } catch {
      editor.value = json;
    }
  } catch (e) {
    editor.value = '{\n  "mcpServers": {}\n}';
  }
}

async function saveConfig() {
  errorEl.classList.add('hidden');
  successEl.classList.add('hidden');

  let json = editor.value;
  try {
    const parsed = JSON.parse(json);
    json = JSON.stringify(parsed, null, 2);
    editor.value = json;
  } catch (e) {
    errorEl.textContent = 'Invalid JSON: ' + e.message;
    errorEl.classList.remove('hidden');
    return;
  }

  try {
    await invoke('save_config_json', { json });
    successEl.classList.remove('hidden');
    setTimeout(() => successEl.classList.add('hidden'), 2000);
    await loadServers();
  } catch (e) {
    errorEl.textContent = String(e);
    errorEl.classList.remove('hidden');
  }
}

async function toggleServer(name, enabled) {
  try {
    // Update the JSON config
    const json = editor.value || await invoke('get_config_json');
    const config = JSON.parse(json);
    if (config.mcpServers && config.mcpServers[name]) {
      config.mcpServers[name].enabled = enabled;
      const updated = JSON.stringify(config, null, 2);
      editor.value = updated;
      await invoke('save_config_json', { json: updated });
      await loadServers();
    }
  } catch (e) {
    errorEl.textContent = 'Failed to toggle: ' + e;
    errorEl.classList.remove('hidden');
  }
}

async function loadServers() {
  try {
    // Get running backends
    const backends = await invoke('list_backends');
    // Also get config to know about disabled servers
    const json = editor.value || await invoke('get_config_json');
    let config;
    try { config = JSON.parse(json); } catch { config = { mcpServers: {} }; }

    renderServers(config.mcpServers || {}, backends || []);
  } catch (e) {
    listEl.innerHTML = '<p class="empty-state">Failed to load status.</p>';
  }
}

function renderServers(configured, running) {
  const names = Object.keys(configured);
  if (names.length === 0) {
    listEl.innerHTML = '<p class="empty-state">No servers configured. Expand "Edit Configuration" to add servers.</p>';
    return;
  }

  // Build a map of running backend status
  const statusMap = {};
  for (const b of running) {
    statusMap[b.name] = b;
  }

  listEl.innerHTML = names.map(name => {
    const cfg = configured[name];
    const backend = statusMap[name];
    const enabled = cfg.enabled !== false;
    const type = cfg.command ? 'stdio' : 'http';

    let statusClass, statusLabel, toolCount, dot;
    if (!enabled) {
      statusClass = 'status-disconnected';
      statusLabel = 'Disabled';
      toolCount = 0;
      dot = '○';
    } else if (backend) {
      statusClass = getStatusClass(backend.status);
      statusLabel = getStatusLabel(backend.status);
      toolCount = backend.tool_count || 0;
      dot = statusClass === 'status-ready' ? '●' : '○';
    } else {
      statusClass = 'status-disconnected';
      statusLabel = 'Not started';
      toolCount = 0;
      dot = '○';
    }

    return `
      <div class="server-row">
        <label class="toggle">
          <input type="checkbox" ${enabled ? 'checked' : ''} data-action="toggle" data-name="${esc(name)}">
          <span class="toggle-slider"></span>
        </label>
        <span class="server-dot ${statusClass}">${dot}</span>
        <span class="server-name">${esc(name)}</span>
        <span class="server-type">${type}</span>
        <span class="server-tools">${toolCount} tools</span>
        <span class="server-status ${statusClass}">${statusLabel}</span>
      </div>
    `;
  }).join('');
}

function getStatusClass(status) {
  if (typeof status === 'object' && status.error) return 'status-error';
  switch (status) {
    case 'ready': return 'status-ready';
    case 'starting': return 'status-starting';
    case 'disconnected': return 'status-disconnected';
    default: return 'status-error';
  }
}

function getStatusLabel(status) {
  if (typeof status === 'object' && status.error) return 'Error';
  switch (status) {
    case 'ready': return 'Ready';
    case 'starting': return 'Starting';
    case 'disconnected': return 'Disabled';
    default: return String(status);
  }
}

function esc(s) {
  const div = document.createElement('div');
  div.textContent = s;
  return div.innerHTML;
}
