export async function enforceContentOnlyWindows(windowsApi) {
  const windows = await windowsApi.getAll({ windowTypes: ["normal"] });
  await Promise.all(windows.map((window) => enforceContentOnlyWindow(window, windowsApi)));
}

export async function enforceContentOnlyWindow(window, windowsApi) {
  if (window?.type !== "normal" || !Number.isInteger(window.id) || window.state === "fullscreen") {
    return false;
  }
  await windowsApi.update(window.id, { state: "fullscreen" });
  return true;
}
