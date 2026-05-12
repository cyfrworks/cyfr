/* =============================================================
   Weather Lookup — app.js
   Fetches weather from wttr.in (no API key required).
   ============================================================= */

// ── DOM refs ────────────────────────────────────────────────
const input       = document.getElementById('city-input');
const searchBtn   = document.getElementById('search-btn');
const retryBtn    = document.getElementById('retry-btn');
const loading     = document.getElementById('loading');
const errorState  = document.getElementById('error-state');
const errorMsg    = document.getElementById('error-msg');
const weatherCard = document.getElementById('weather-card');
const promptState = document.getElementById('prompt-state');

// Weather card fields
const elCity      = document.getElementById('city-name');
const elCountry   = document.getElementById('country-name');
const elEmoji     = document.getElementById('weather-emoji');
const elDesc      = document.getElementById('weather-desc');
const elTempC     = document.getElementById('temp-c');
const elTempF     = document.getElementById('temp-f');
const elFeels     = document.getElementById('feels-like');
const elHumidity  = document.getElementById('humidity');
const elWind      = document.getElementById('wind');
const elUpdated   = document.getElementById('last-updated');

// ── State ────────────────────────────────────────────────────
let lastCity = '';

// ── Weather emoji mapping ───────────────────────────────────
/**
 * Map a wttr.in weather description string to a relevant emoji.
 * Tries to match keywords in order from most-specific to generic.
 */
function getWeatherEmoji(desc) {
  const d = (desc || '').toLowerCase();

  if (d.includes('thunder') || d.includes('storm')) return '⛈️';
  if (d.includes('tornado'))                         return '🌪️';
  if (d.includes('blizzard'))                        return '🌨️';
  if (d.includes('snow') || d.includes('sleet'))     return '❄️';
  if (d.includes('hail') || d.includes('ice'))       return '🧊';
  if (d.includes('freezing'))                        return '🥶';
  if (d.includes('heavy rain') || d.includes('downpour')) return '🌧️';
  if (d.includes('drizzle') || d.includes('light rain')) return '🌦️';
  if (d.includes('rain') || d.includes('shower'))    return '🌧️';
  if (d.includes('fog') || d.includes('mist') || d.includes('haze')) return '🌫️';
  if (d.includes('overcast'))                        return '☁️';
  if (d.includes('cloudy') && d.includes('partly'))  return '⛅';
  if (d.includes('cloudy'))                          return '🌥️';
  if (d.includes('sunny') || d.includes('clear'))    return '☀️';
  if (d.includes('wind') || d.includes('breezy'))    return '💨';
  if (d.includes('hot'))                             return '🌡️';

  // Fallback
  return '🌤️';
}

// ── UI state helpers ─────────────────────────────────────────
function showOnly(id) {
  const panels = ['loading', 'error-state', 'weather-card', 'prompt-state'];
  panels.forEach(p => {
    const el = document.getElementById(p);
    if (p === id) {
      el.classList.remove('hidden');
    } else {
      el.classList.add('hidden');
    }
  });
}

function setSearching(active) {
  searchBtn.disabled = active;
  input.disabled = active;
  searchBtn.querySelector('.btn-icon').textContent = active ? '…' : '→';
}

// ── Core fetch ───────────────────────────────────────────────
async function fetchWeather(city) {
  if (!city || !city.trim()) {
    input.focus();
    return;
  }

  lastCity = city.trim();
  setSearching(true);
  showOnly('loading');

  try {
    const encoded = encodeURIComponent(lastCity);
    const url = `https://wttr.in/${encoded}?format=j1`;

    const res = await fetch(url);

    if (!res.ok) {
      throw new Error(`HTTP ${res.status}: Could not fetch weather data.`);
    }

    const data = await res.json();

    // Validate response shape
    if (!data || !data.current_condition || !data.current_condition[0]) {
      throw new Error('City not found or no weather data available.');
    }

    renderWeather(data);
    showOnly('weather-card');

  } catch (err) {
    let msg = err.message || 'Something went wrong. Please try again.';

    // Friendlier messages for common failures
    if (msg.includes('404') || msg.includes('not found') || msg.toLowerCase().includes('city')) {
      msg = `🌍 Could not find weather for "${lastCity}". Check the spelling and try again.`;
    } else if (msg.includes('Failed to fetch') || msg.includes('NetworkError')) {
      msg = 'Unable to connect to the weather service. Check your internet connection.';
    }

    errorMsg.textContent = msg;
    showOnly('error-state');
  } finally {
    setSearching(false);
  }
}

// ── Render weather data ──────────────────────────────────────
function renderWeather(data) {
  const cc = data.current_condition[0];
  const area = data.nearest_area ? data.nearest_area[0] : null;

  const desc       = cc.weatherDesc?.[0]?.value   || 'Unknown';
  const tempC      = cc.temp_C                     || '—';
  const tempF      = cc.temp_F                     || '—';
  const feelsC     = cc.FeelsLikeC                 || '—';
  const feelsF     = cc.FeelsLikeF                 || '—';
  const humidity   = cc.humidity                   || '—';
  const windKmph   = cc.windspeedKmph              || '—';
  const cityName   = area?.areaName?.[0]?.value    || lastCity;
  const countryName = area?.country?.[0]?.value    || '';

  elEmoji.textContent    = getWeatherEmoji(desc);
  elDesc.textContent     = desc;
  elCity.textContent     = cityName;
  elCountry.textContent  = countryName;
  elTempC.textContent    = `${tempC}°C`;
  elTempF.textContent    = `${tempF}°F`;
  elFeels.textContent    = `${feelsC}°C / ${feelsF}°F`;
  elHumidity.textContent = `${humidity}%`;
  elWind.textContent     = `${windKmph} km/h`;
  elUpdated.textContent  = `Updated at ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
}

// ── Event listeners ──────────────────────────────────────────
searchBtn.addEventListener('click', () => fetchWeather(input.value));

input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') fetchWeather(input.value);
});

retryBtn.addEventListener('click', () => {
  if (lastCity) {
    input.value = lastCity;
    fetchWeather(lastCity);
  } else {
    showOnly('prompt-state');
    input.focus();
  }
});

// ── Init ─────────────────────────────────────────────────────
cyfr.ready();
input.focus();
showOnly('prompt-state');
