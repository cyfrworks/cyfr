const DOCKER_INSTALL_URL = 'https://www.docker.com/products/docker-desktop/';
const CLI_DOWNLOAD_URL = 'https://github.com/cyfrworks/cyfr/releases';

// DOM elements
const progressView = document.getElementById('progress-view');
const progressEl = document.getElementById('progress');
const statusEl = document.getElementById('status');
const dockerNotFound = document.getElementById('docker-not-found');
const notFoundMessage = document.getElementById('not-found-message');
const dockerNotRunning = document.getElementById('docker-not-running');
const notRunningMessage = document.getElementById('not-running-message');
const cliNotFound = document.getElementById('cli-not-found');
const cliNotFoundMessage = document.getElementById('cli-not-found-message');
const errorView = document.getElementById('error-view');
const errorMessage = document.getElementById('error-message');

// Current state for cleanup
let currentState = 'checking';

function showView(viewId) {
  const views = ['progress-view', 'docker-not-found', 'docker-not-running', 'docker-installing', 'cli-not-found', 'error-view'];
  views.forEach(id => {
    document.getElementById(id).classList.toggle('hidden', id !== viewId);
  });
}

function renderState(state, message, progress) {
  currentState = state;

  switch (state) {
    case 'checking':
    case 'installing_cli':
    case 'init':
    case 'starting':
      showView('progress-view');
      statusEl.textContent = message;
      if (progress != null) {
        progressEl.style.width = (progress * 100) + '%';
      }
      progressEl.style.background = '';
      progressEl.style.animation = progress >= 1.0 ? 'none' : '';
      break;

    case 'ready':
      showView('progress-view');
      statusEl.textContent = message;
      progressEl.style.width = '100%';
      progressEl.style.animation = 'none';
      break;

    case 'docker_not_found':
      showView('docker-not-found');
      notFoundMessage.textContent = message;
      break;

    case 'installing_docker':
      showView('docker-installing');
      document.getElementById('install-status').textContent = message;
      if (progress != null) {
        const bar = document.getElementById('install-progress');
        bar.style.width = (progress * 100) + '%';
        bar.style.animation = progress >= 1.0 ? 'none' : '';
      }
      break;

    case 'docker_not_running':
      showView('docker-not-running');
      notRunningMessage.textContent = message;
      break;

    case 'cli_not_found':
      showView('cli-not-found');
      cliNotFoundMessage.textContent = message;
      break;

    case 'error':
      showView('error-view');
      errorMessage.textContent = message;
      break;
  }
}

async function retryBoot() {
  showView('progress-view');
  statusEl.textContent = 'Retrying...';
  progressEl.style.width = '5%';
  progressEl.style.background = '';
  progressEl.style.animation = '';

  try {
    const tauri = window.__TAURI__;
    if (tauri && tauri.core) {
      await tauri.core.invoke('retry_boot');
    }
  } catch (e) {
    renderState('error', String(e), null);
  }
}

async function openDockerDesktop() {
  const btn = document.getElementById('open-docker-btn');
  const retryBtn = document.getElementById('retry-not-running-btn');
  const titleEl = document.querySelector('#docker-not-running .state-title');

  // Show "Starting Docker" state
  btn.disabled = true;
  btn.textContent = 'Starting Docker...';
  btn.classList.add('btn-loading');
  retryBtn.classList.add('hidden');
  if (titleEl) titleEl.textContent = 'Starting Docker';
  notRunningMessage.textContent = 'Waiting for Docker Desktop to start...';

  try {
    const tauri = window.__TAURI__;
    if (tauri && tauri.core) {
      await tauri.core.invoke('open_docker_desktop');

      // Poll for Docker readiness every 2s, up to 60s
      for (let i = 0; i < 30; i++) {
        await new Promise(r => setTimeout(r, 2000));
        try {
          const ready = await tauri.core.invoke('check_docker_ready');
          if (ready) {
            // Docker is ready — trigger boot sequence
            await tauri.core.invoke('retry_boot');
            return;
          }
        } catch (e) {
          // Keep waiting
        }
      }

      // Timeout — restore buttons
      if (titleEl) titleEl.textContent = 'Docker Desktop Not Running';
      notRunningMessage.textContent = 'Docker Desktop did not start in time. Try again.';
      btn.disabled = false;
      btn.textContent = 'Open Docker Desktop';
      btn.classList.remove('btn-loading');
      retryBtn.classList.remove('hidden');
    }
  } catch (e) {
    if (titleEl) titleEl.textContent = 'Docker Desktop Not Running';
    btn.disabled = false;
    btn.textContent = 'Open Docker Desktop';
    btn.classList.remove('btn-loading');
    retryBtn.classList.remove('hidden');
  }
}

async function installDocker() {
  const tauri = window.__TAURI__;
  if (tauri && tauri.core) {
    // Switch to installing view immediately
    renderState('installing_docker', 'Preparing download...', 0.05);
    try {
      await tauri.core.invoke('install_docker');
      // If successful, install_docker triggers retry_boot internally
    } catch (e) {
      renderState('error', 'Docker installation failed: ' + String(e), null);
    }
  }
}

function manualInstallDocker() {
  const tauri = window.__TAURI__;
  if (tauri && tauri.shell) {
    tauri.shell.open(DOCKER_INSTALL_URL);
  }
}

function downloadCli() {
  const tauri = window.__TAURI__;
  if (tauri && tauri.shell) {
    tauri.shell.open(CLI_DOWNLOAD_URL);
  }
}

// Bind event listeners
document.getElementById('install-docker-btn').addEventListener('click', installDocker);
document.getElementById('manual-docker-btn').addEventListener('click', manualInstallDocker);
document.getElementById('retry-not-found-btn').addEventListener('click', retryBoot);
document.getElementById('open-docker-btn').addEventListener('click', openDockerDesktop);
document.getElementById('retry-not-running-btn').addEventListener('click', retryBoot);
document.getElementById('download-cli-btn').addEventListener('click', downloadCli);
document.getElementById('retry-cli-btn').addEventListener('click', retryBoot);
document.getElementById('retry-error-btn').addEventListener('click', retryBoot);

// Wait for Tauri IPC to be ready, bind listeners, then trigger boot
let tauriAttempts = 0;

function initTauri() {
  tauriAttempts++;
  const tauri = window.__TAURI__;

  if (!tauri || !tauri.event || !tauri.core) {
    // Show debug info after 2 seconds of waiting
    if (tauriAttempts > 40) {
      statusEl.textContent = 'Waiting for runtime... (fallback in ' + Math.max(0, Math.ceil(3 - tauriAttempts * 0.05)) + 's)';
    }
    setTimeout(initTauri, 50);
    return;
  }

  // Bind event listener FIRST
  tauri.event.listen('boot-state', (event) => {
    const { state, message, progress } = event.payload;
    renderState(state, message, progress);
  });

  statusEl.textContent = 'Starting...';

  // THEN trigger boot sequence — guarantees no events are missed
  tauri.core.invoke('start_boot').catch((e) => {
    renderState('error', 'Failed to start: ' + e, null);
  });
}

initTauri();
