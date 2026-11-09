/* Starts the switchboard: opens the streams, draws the board, and tells the
   shell it is ready once every stream's first open has its answer. If the
   board cannot be drawn, the plain listing of the same state stands in for
   it, so a drawing fault never costs the person their desktop. */
(function () {
  'use strict';

  const plain = document.getElementById('plain');
  const board = document.getElementById('console');
  let boardUp = false;

  function fallBack() {
    boardUp = false;
    board.hidden = true;
    document.documentElement.classList.remove('live-console');
    window.Plain.render(plain);
  }

  try {
    if (!window.cyfr) throw new Error('no shell');
    window.Board.mount(window.cyfr, board);
    board.hidden = false;
    document.documentElement.classList.add('live-console');
    boardUp = true;
  } catch (_) {
    fallBack();
  }

  window.SB.subscribe((kinds) => {
    if (boardUp) {
      try { window.Board.render(kinds); return; } catch (_) { fallBack(); return; }
    }
    window.Plain.render(plain);
  });

  // Outside CYFR's shell there is no SDK and nothing to read.
  if (window.cyfr) window.SB.start(window.cyfr, () => window.cyfr.ready());
  else fallBack();
})();
