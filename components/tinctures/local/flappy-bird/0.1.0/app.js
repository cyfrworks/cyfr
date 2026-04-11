(function() {
  'use strict';

  if (typeof cyfr !== 'undefined' && cyfr.ready) cyfr.ready();

  var canvas = document.getElementById('c');
  var ctx    = canvas.getContext('2d');

  var W = 360, H = 640;

  function resize() {
    var vw = window.innerWidth  || document.documentElement.clientWidth  || W;
    var vh = window.innerHeight || document.documentElement.clientHeight || H;
    if (vw < 1) vw = W;
    if (vh < 1) vh = H;
    var scale = Math.min(vw / W, vh / H);
    canvas.width  = W;
    canvas.height = H;
    canvas.style.width  = Math.floor(W * scale) + 'px';
    canvas.style.height = Math.floor(H * scale) + 'px';
  }
  resize();
  window.addEventListener('resize', resize);

  var GRAV     = 0.45;
  var FLAP_V   = -9.0;
  var PIPE_SPD = 2.6;
  var PIPE_W   = 58;
  var PIPE_GAP = 155;
  var PIPE_INT = 1500;
  var GND_H    = 72;
  var BIRD_X   = 90;
  var BIRD_W   = 38;
  var BIRD_H   = 28;

  var ST    = { START: 0, PLAY: 1, DEAD: 2 };
  var state = ST.START;
  var score = 0;
  var best  = 0;
  var tick  = 0;

  var bird = { x: BIRD_X, y: H/2-30, vy: 0, angle: 0, wing: 0, wt: 0, dead: false };

  function resetBird() {
    bird.x = BIRD_X; bird.y = H/2-30; bird.vy = 0;
    bird.angle = 0; bird.wing = 0; bird.wt = 0; bird.dead = false;
  }

  var pipes    = [];
  var nextPipe = 0;

  function addPipe() {
    var min  = 80;
    var max  = H - GND_H - PIPE_GAP - 80;
    var topH = min + Math.random() * (max - min);
    pipes.push({ x: W + 10, topH: topH, scored: false });
  }

  var clouds = [
    { x:  60, y:  70, w:  90, h: 34, s: 0.35 },
    { x: 220, y:  45, w:  70, h: 26, s: 0.25 },
    { x: 310, y: 100, w: 110, h: 38, s: 0.40 },
    { x: 130, y: 130, w:  60, h: 22, s: 0.20 },
    { x: 430, y:  60, w:  80, h: 30, s: 0.30 }
  ];

  var particles = [];
  function burst(x, y) {
    for (var i = 0; i < 18; i++) {
      var a  = (Math.PI * 2 * i / 18) + Math.random() * 0.3;
      var sp = 1.5 + Math.random() * 4;
      particles.push({
        x: x, y: y,
        vx: Math.cos(a) * sp, vy: Math.sin(a) * sp - 2,
        life: 1, decay: 0.03 + Math.random() * 0.04,
        r: 3 + Math.random() * 4,
        col: ['#FFD600','#FFA000','#FF6F00','#fff'][Math.floor(Math.random() * 4)]
      });
    }
  }

  function action() {
    if      (state === ST.START) { startGame(); }
    else if (state === ST.PLAY)  { flap(); }
    else if (state === ST.DEAD)  { startGame(); }
  }
  function flap() {
    if (bird.dead) return;
    bird.vy = FLAP_V; bird.wing = 1; bird.wt = 0;
  }

  canvas.addEventListener('click',      action);
  canvas.addEventListener('touchstart', function(e) { e.preventDefault(); action(); }, { passive: false });
  document.addEventListener('keydown',  function(e) {
    if (e.code === 'Space' || e.code === 'ArrowUp') { e.preventDefault(); action(); }
  });

  function startGame() {
    state = ST.PLAY; score = 0;
    resetBird(); pipes = []; particles = [];
    nextPipe = performance.now() + PIPE_INT;
    flap();
  }

  function killBird() {
    if (bird.dead) return;
    bird.dead = true;
    bird.vy   = FLAP_V * 0.5;
    burst(bird.x, bird.y);
    if (score > best) best = score;
    setTimeout(function() { state = ST.DEAD; }, 700);
  }

  function collide() {
    if (bird.dead) return;
    var bx = bird.x - BIRD_W * 0.38, by = bird.y - BIRD_H * 0.38;
    var bw = BIRD_W * 0.76,          bh = BIRD_H * 0.76;
    if (bird.y + BIRD_H / 2 >= H - GND_H) { killBird(); return; }
    if (bird.y - BIRD_H / 2 <= 0) { bird.y = BIRD_H / 2; bird.vy = 0; }
    for (var i = 0; i < pipes.length; i++) {
      var p = pipes[i];
      if (bx + bw > p.x && bx < p.x + PIPE_W) {
        if (by < p.topH || by + bh > p.topH + PIPE_GAP) { killBird(); return; }
      }
      if (!p.scored && p.x + PIPE_W < bird.x) { p.scored = true; score++; }
    }
  }

  function update(dt, now) {
    for (var i = 0; i < clouds.length; i++) {
      clouds[i].x -= clouds[i].s * dt * 0.06;
      if (clouds[i].x + clouds[i].w < 0) clouds[i].x = W + clouds[i].w;
    }
    if (state === ST.START) return;

    if (!bird.dead || bird.y < H - GND_H + 20) {
      bird.vy   += GRAV * dt * 0.06;
      bird.y    += bird.vy * dt * 0.06;
      bird.angle = Math.max(-0.4, Math.min(Math.PI / 2, bird.vy * 0.065));
    }
    bird.wt += dt;
    if (bird.wt > 120) { bird.wing = bird.wing === 0 ? 1 : 0; bird.wt = 0; }

    if (!bird.dead && now >= nextPipe) {
      addPipe();
      nextPipe = now + PIPE_INT;
    }

    for (var j = 0; j < pipes.length; j++) pipes[j].x -= PIPE_SPD * dt * 0.06;
    pipes = pipes.filter(function(p) { return p.x + PIPE_W > -10; });

    for (var k = 0; k < particles.length; k++) {
      var pt = particles[k];
      pt.x    += pt.vx * dt * 0.06;
      pt.y    += pt.vy * dt * 0.06;
      pt.vy   += 0.25  * dt * 0.06;
      pt.life -= pt.decay * dt * 0.06;
    }
    particles = particles.filter(function(p) { return p.life > 0; });
    collide();
  }

  function rr(x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);     ctx.quadraticCurveTo(x + w, y,     x + w, y + r);
    ctx.lineTo(x + w, y + h - r); ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    ctx.lineTo(x + r, y + h);     ctx.quadraticCurveTo(x,     y + h, x,     y + h - r);
    ctx.lineTo(x, y + r);         ctx.quadraticCurveTo(x,     y,     x + r, y);
    ctx.closePath();
  }

  function txt(s, x, y, size, col, shadow) {
    ctx.font         = 'bold ' + size + 'px "Courier New",monospace';
    ctx.textAlign    = 'center';
    ctx.textBaseline = 'middle';
    if (shadow) { ctx.fillStyle = shadow; ctx.fillText(s, x + 2, y + 2); }
    ctx.fillStyle = col; ctx.fillText(s, x, y);
  }

  function drawSky() {
    var g = ctx.createLinearGradient(0, 0, 0, H - GND_H);
    g.addColorStop(0, '#4fc3f7');
    g.addColorStop(1, '#81d4fa');
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H - GND_H);
  }

  function drawCloud(x, y, w, h) {
    ctx.fillStyle = 'rgba(255,255,255,0.8)';
    ctx.beginPath(); ctx.ellipse(x+w*0.50, y+h*0.65, w*0.46, h*0.42, 0, 0, Math.PI*2); ctx.fill();
    ctx.beginPath(); ctx.ellipse(x+w*0.25, y+h*0.72, w*0.26, h*0.35, 0, 0, Math.PI*2); ctx.fill();
    ctx.beginPath(); ctx.ellipse(x+w*0.72, y+h*0.72, w*0.24, h*0.30, 0, 0, Math.PI*2); ctx.fill();
    ctx.beginPath(); ctx.ellipse(x+w*0.50, y+h*0.38, w*0.28, h*0.32, 0, 0, Math.PI*2); ctx.fill();
  }

  function drawGround() {
    var gy  = H - GND_H;
    var off = (tick * 0.4) % 18;
    ctx.fillStyle = '#8B6914'; ctx.fillRect(0, gy, W, GND_H);
    ctx.fillStyle = '#5cb85c'; ctx.fillRect(0, gy, W, 14);
    ctx.fillStyle = '#4cae4c';
    for (var i = -18; i < W + 18; i += 18) { ctx.fillRect(i - off, gy + 2, 8, 4); }
  }

  function drawPipe(x, topH) {
    var capH = 22, capW = PIPE_W + 10, capX = x - 5;
    var tg = ctx.createLinearGradient(x, 0, x + PIPE_W, 0);
    tg.addColorStop(0, '#1b5e20'); tg.addColorStop(0.20, '#43a047');
    tg.addColorStop(0.55, '#2e7d32'); tg.addColorStop(1, '#1b5e20');
    ctx.fillStyle = tg; ctx.fillRect(x, 0, PIPE_W, topH);
    var tcg = ctx.createLinearGradient(capX, 0, capX + capW, 0);
    tcg.addColorStop(0, '#1b5e20'); tcg.addColorStop(0.15, '#66bb6a');
    tcg.addColorStop(0.50, '#388e3c'); tcg.addColorStop(1, '#1b5e20');
    ctx.fillStyle = tcg; rr(capX, topH - capH, capW, capH, 4); ctx.fill();
    var botY = topH + PIPE_GAP, botH = H - GND_H - botY;
    var bg = ctx.createLinearGradient(x, 0, x + PIPE_W, 0);
    bg.addColorStop(0, '#1b5e20'); bg.addColorStop(0.20, '#43a047');
    bg.addColorStop(0.55, '#2e7d32'); bg.addColorStop(1, '#1b5e20');
    ctx.fillStyle = bg; ctx.fillRect(x, botY, PIPE_W, botH);
    var bcg = ctx.createLinearGradient(capX, 0, capX + capW, 0);
    bcg.addColorStop(0, '#1b5e20'); bcg.addColorStop(0.15, '#66bb6a');
    bcg.addColorStop(0.50, '#388e3c'); bcg.addColorStop(1, '#1b5e20');
    ctx.fillStyle = bcg; rr(capX, botY, capW, capH, 4); ctx.fill();
  }

  function drawBird(bx, by, angle, wing) {
    ctx.save();
    ctx.translate(bx, by);
    ctx.rotate(angle);
    var hw = BIRD_W / 2, hh = BIRD_H / 2;
    ctx.fillStyle = '#FFA000';
    if (wing === 0) {
      ctx.beginPath(); ctx.ellipse(-2,  hh*0.4,  hw*0.5, hh*0.45, -0.3, 0, Math.PI*2); ctx.fill();
    } else {
      ctx.beginPath(); ctx.ellipse(-2, -hh*0.5,  hw*0.5, hh*0.38,  0.4, 0, Math.PI*2); ctx.fill();
    }
    var bg2 = ctx.createRadialGradient(-2, -2, 2, 0, 0, hw * 1.1);
    bg2.addColorStop(0,   '#FFE57F');
    bg2.addColorStop(0.6, '#FFD600');
    bg2.addColorStop(1,   '#FFA000');
    ctx.fillStyle = bg2;
    ctx.beginPath(); ctx.ellipse(0, 0, hw, hh, 0, 0, Math.PI*2); ctx.fill();
    ctx.fillStyle = '#FFF9C4';
    ctx.beginPath(); ctx.ellipse(4, 3, hw*0.42, hh*0.40, 0.2, 0, Math.PI*2); ctx.fill();
    ctx.fillStyle = '#fff';
    ctx.beginPath(); ctx.arc(hw*0.45, -hh*0.18, 6, 0, Math.PI*2); ctx.fill();
    ctx.fillStyle = '#212121';
    ctx.beginPath(); ctx.arc(hw*0.45+1.5, -hh*0.18+1, 3.2, 0, Math.PI*2); ctx.fill();
    ctx.fillStyle = 'rgba(255,255,255,0.8)';
    ctx.beginPath(); ctx.arc(hw*0.45+2.5, -hh*0.18-1, 1.4, 0, Math.PI*2); ctx.fill();
    ctx.strokeStyle = '#E65100'; ctx.lineWidth = 2.2; ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(hw*0.45-5, -hh*0.18-6.5);
    ctx.lineTo(hw*0.45+5, -hh*0.18-5);
    ctx.stroke();
    ctx.fillStyle = '#FF6F00';
    ctx.beginPath();
    ctx.moveTo(hw*0.75, -hh*0.05); ctx.lineTo(hw*1.3, -hh*0.15);
    ctx.lineTo(hw*1.3,   hh*0.10); ctx.lineTo(hw*0.75,  hh*0.18);
    ctx.closePath(); ctx.fill();
    ctx.restore();
  }

  function drawStart() {
    var pw = 260, ph = 76, px = W/2 - 130, py = 120;
    ctx.fillStyle = 'rgba(13,33,55,0.93)'; rr(px, py, pw, ph, 12); ctx.fill();
    ctx.strokeStyle = '#4fc3f7'; ctx.lineWidth = 2; rr(px, py, pw, ph, 12); ctx.stroke();
    txt('FLAPPY', W/2, py + 24, 34, '#FFD600', '#00000099');
    txt('BIRD',   W/2, py + 55, 34, '#FFD600', '#00000099');
    var bobY      = Math.sin(tick * 0.05) * 8;
    var animAngle = Math.sin(tick * 0.06) * 0.15;
    var animWing  = tick % 24 < 12 ? 0 : 1;
    ctx.save();
    ctx.translate(W/2, 290 + bobY);
    ctx.scale(1.6, 1.6);
    drawBird(0, 0, animAngle, animWing);
    ctx.restore();
    if (best > 0) txt('BEST: ' + best, W/2, 370, 16, '#FFD600', '#00000088');
    var pulse = 0.65 + 0.35 * Math.sin(tick * 0.07);
    ctx.globalAlpha = pulse;
    txt('TAP TO START', W/2, 430, 18, '#ffffff', '#00000088');
    ctx.globalAlpha = 1;
    txt('SPACE / CLICK / TAP', W/2, 462, 11, '#aaaaaa', null);
  }

  function drawOver() {
    ctx.fillStyle = 'rgba(0,0,0,0.6)'; ctx.fillRect(0, 0, W, H);
    var pw = 290, ph = 260, px = W/2 - 145, py = H/2 - 150;
    ctx.fillStyle = 'rgba(13,33,55,0.95)'; rr(px, py, pw, ph, 14); ctx.fill();
    ctx.strokeStyle = '#4fc3f7'; ctx.lineWidth = 2.5; rr(px, py, pw, ph, 14); ctx.stroke();
    txt('GAME OVER', W/2, py + 32, 26, '#fff', '#ef535099');
    ctx.fillStyle = '#4fc3f7'; ctx.fillRect(px + 20, py + 50, pw - 40, 2);
    txt('SCORE', px + 80,  py + 76,  13, '#90caf9', null);
    txt(score,   px + 80,  py + 100, 22, '#fff', '#00000088');
    txt('BEST',  px + 210, py + 76,  13, '#90caf9', null);
    txt(best,    px + 210, py + 100, 22, (score >= best && score > 0) ? '#FFD600' : '#fff', '#00000088');
    if (score >= best && score > 0) txt('NEW!', px + 210, py + 60, 10, '#FFD600', null);
    ctx.fillStyle = '#2e7d32'; rr(px + 85, py + 140, 120, 44, 8); ctx.fill();
    ctx.fillStyle = '#43a047'; rr(px + 85, py + 140, 120, 40, 8); ctx.fill();
    txt('▶  PLAY', W/2, py + 160, 15, '#fff', '#00000077');
    txt('TAP / CLICK / SPACE', W/2, py + 204, 10, '#666', null);
  }

  var lastTime = null;

  function loop(ts) {
    if (lastTime === null) lastTime = ts;
    var dt = ts - lastTime;
    if (dt > 50) dt = 50;
    lastTime = ts;
    tick++;

    update(dt, ts);

    drawSky();
    for (var i = 0; i < clouds.length; i++) drawCloud(clouds[i].x, clouds[i].y, clouds[i].w, clouds[i].h);
    for (var j = 0; j < pipes.length;  j++) drawPipe(pipes[j].x, pipes[j].topH);
    drawGround();

    for (var k = 0; k < particles.length; k++) {
      var p = particles[k];
      ctx.globalAlpha = p.life;
      ctx.fillStyle   = p.col;
      ctx.beginPath(); ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2); ctx.fill();
    }
    ctx.globalAlpha = 1;

    if (state !== ST.START) drawBird(bird.x, bird.y, bird.angle, bird.wing);
    if (state === ST.PLAY)  txt(score, W/2, 60, 48, '#fff', '#00000088');
    if (state === ST.START) drawStart();
    if (state === ST.DEAD)  { txt(score, W/2, 60, 48, '#fff', '#00000088'); drawOver(); }

    requestAnimationFrame(loop);
  }

  requestAnimationFrame(loop);

})();
