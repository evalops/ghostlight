const SENSITIVE_QUERY_NAMES = new Set([
  "accesstoken", "apikey", "auth", "authorization", "code", "cookie",
  "credential", "idtoken", "jwt", "key", "password", "passwd",
  "refreshtoken", "secret", "session", "sessionid", "sessiontoken", "sig",
  "signature", "token", "xamzcredential", "xamzsecuritytoken",
  "xamzsignature", "xgoogcredential", "xgoogsecuritytoken", "xgoogsignature"
]);

export function normalizeControlOrigin(value) {
  const url = new URL(value.trim());
  if (!["http:", "https:"].includes(url.protocol) || !url.hostname || url.username || url.password || url.search || url.hash) {
    throw new Error("Enter an HTTP or HTTPS control URL without credentials, query parameters, or a fragment.");
  }
  url.pathname = url.pathname.replace(/\/+$/, "");
  return url.toString().replace(/\/$/, "");
}

export function safeHandoff(tab) {
  if (tab.incognito) throw new Error("Incognito tabs cannot be sent to Ghostlight.");
  const url = new URL(tab.url ?? "");
  if (!["http:", "https:"].includes(url.protocol) || !url.hostname || url.username || url.password || url.hash) {
    throw new Error("Only HTTP or HTTPS pages without credentials or fragments can be sent.");
  }
  for (const name of url.searchParams.keys()) {
    const normalized = name.toLowerCase().replace(/[^a-z0-9]/g, "");
    if (SENSITIVE_QUERY_NAMES.has(normalized) || normalized.endsWith("token") || normalized.endsWith("password")) {
      throw new Error("This URL appears to contain a credential and was not sent.");
    }
  }
  return { title: (tab.title ?? "").trim().slice(0, 300), url: url.toString() };
}

export function safeHandoffs(tabs, limit = 25) {
  const handoffs = tabs.map(safeHandoff);
  if (handoffs.length === 0) throw new Error("Choose at least one normal web page.");
  if (handoffs.length > limit) throw new Error(`Ghostlight accepts up to ${limit} tabs at once.`);
  return handoffs;
}

export function bookmarkItems(nodes) {
  const values = [];
  const visit = (node, position = 0) => {
    const item = {
      external_id: String(node.id),
      parent_external_id: node.parentId ? String(node.parentId) : "",
      title: (node.title ?? "").trim().slice(0, 300),
      position
    };
    if (node.url) {
      const url = safeLibraryURL(node.url);
      if (!url) return;
      item.url = url;
    }
    values.push(item);
    for (const [index, child] of (node.children ?? []).entries()) visit(child, index);
  };
  for (const [index, node] of nodes.entries()) visit(node, index);
  return values;
}

export function readingListItems(entries) {
  return entries.flatMap((entry, position) => {
    const url = safeLibraryURL(entry.url);
    if (!url) return [];
    return [{
      external_id: url,
      title: (entry.title ?? "").trim().slice(0, 300),
      url,
      position,
      read: Boolean(entry.hasBeenRead)
    }];
  });
}

function safeLibraryURL(value) {
  try {
    return safeHandoff({ url: value }).url;
  } catch {
    return null;
  }
}

export function endpoint(controlOrigin, path) {
  return `${normalizeControlOrigin(controlOrigin)}/${path.replace(/^\/+/, "")}`;
}

export function hostPermission(controlOrigin) {
  const url = new URL(normalizeControlOrigin(controlOrigin));
  return `${url.origin}/*`;
}
