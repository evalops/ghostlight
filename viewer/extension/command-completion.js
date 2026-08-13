const completionPrefix = "ghostlight.command.";

async function completeCommand(command, storage, execute, acknowledge) {
  const key = completionPrefix + command.id;
  const stored = await storage.get(key);
  let completion = stored[key];
  if (!completion) {
    try {
      completion = { status: "ok", result: await execute(command) };
    } catch (error) {
      completion = { status: "failed", error: String(error?.message || error) };
    }
    await storage.set({ [key]: completion });
  }
  await acknowledge(command.id, completion);
  await storage.remove(key);
  return completion;
}

export { completeCommand };
