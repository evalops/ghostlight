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

export function endpoint(controlOrigin, path) {
  return `${normalizeControlOrigin(controlOrigin)}/${path.replace(/^\/+/, "")}`;
}

export function hostPermission(controlOrigin) {
  const url = new URL(normalizeControlOrigin(controlOrigin));
  return `${url.origin}/*`;
}
