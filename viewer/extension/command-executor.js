import { validateNavigationURL } from "./protocol.js";

async function executeCommand(command, tabs, nativeRequest) {
  switch (command.type) {
    case "navigate":
      if (command.tab_id) {
        return tabs.update(Number(command.tab_id), { url: validateNavigationURL(command.url) });
      }
      return tabs.update({ url: validateNavigationURL(command.url) });
    case "activate_tab":
      return tabs.update(Number(command.tab_id), { active: true });
    case "create_tab":
      return tabs.create({ url: validateNavigationURL(command.url), active: true });
    case "close_tab":
      await tabs.remove(Number(command.tab_id));
      return {};
    case "back":
      await tabs.goBack(Number(command.tab_id));
      return {};
    case "forward":
      await tabs.goForward(Number(command.tab_id));
      return {};
    case "reload":
      await tabs.reload(Number(command.tab_id));
      return {};
    case "stage_attachment":
      return nativeRequest({ operation: "stage_attachment", attachment_id: command.attachment_id });
    case "restore_space": {
      const destinations = command.destinations.map(validateNavigationURL);
      const existing = (await tabs.query({})).sort((left, right) => left.index - right.index);
      const restored = [];
      if (existing.length > 0) {
        restored.push(await tabs.update(existing[0].id, { url: destinations[0], active: false }));
      } else {
        restored.push(await tabs.create({ url: destinations[0], active: false }));
      }
      for (const destination of destinations.slice(1)) {
        restored.push(await tabs.create({ url: destination, active: false }));
      }
      if (existing.length > 1) {
        await tabs.remove(existing.slice(1).map((tab) => tab.id));
      }
      const activeID = restored[command.active_position]?.id;
      if (!Number.isInteger(activeID)) throw new Error("restored tab omitted its id");
      await tabs.update(activeID, { active: true });
      return { restored_tabs: restored.length, active_position: command.active_position };
    }
    default:
      throw new Error(`unsupported command type: ${command.type}`);
  }
}

export { executeCommand };
