// Starts the village, or the plain list when the scene cannot run, then the streams. The desktop
// is ready once every stream's first open has its answer: opened, refused, or to be tried again.
(function () {
  try { RoadScene(); } catch (e) { console.error(e); RoadList.show(); }
  Road.start().then(() => Road.ready());
})();
