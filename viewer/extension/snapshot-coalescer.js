function createSnapshotPublisher(publish) {
  let dirty = false;
  let running;

  return function requestSnapshot() {
    dirty = true;
    if (!running) {
      running = (async () => {
        while (dirty) {
          dirty = false;
          await publish();
        }
      })().finally(() => {
        running = undefined;
      });
    }
    return running;
  };
}

export { createSnapshotPublisher };
