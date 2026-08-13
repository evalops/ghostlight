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
    default:
      throw new Error(`unsupported command type: ${command.type}`);
  }
}

export { executeCommand };
