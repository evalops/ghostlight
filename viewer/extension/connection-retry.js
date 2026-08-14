const initialReconnectMilliseconds = 500;
const maximumReconnectMilliseconds = 30000;
const minimumAlarmMilliseconds = 30000;

function createReconnectScheduler(
  alarms,
  alarmName,
  now = () => Date.now(),
  setTimer = (callback, delay) => setTimeout(callback, delay),
  clearTimer = (timer) => clearTimeout(timer),
) {
  let attempt = 0;
  let timer;

  return {
    schedule(callback) {
      attempt += 1;
      const delay = Math.min(
        initialReconnectMilliseconds * (2 ** (attempt - 1)),
        maximumReconnectMilliseconds,
      );
      if (timer !== undefined) clearTimer(timer);
      timer = setTimer(callback, delay);
      alarms.create(alarmName, { when: now() + Math.max(delay, minimumAlarmMilliseconds) });
      return delay;
    },
    reset() {
      attempt = 0;
      if (timer !== undefined) {
        clearTimer(timer);
        timer = undefined;
      }
      alarms.clear(alarmName);
    },
  };
}

export { createReconnectScheduler };
