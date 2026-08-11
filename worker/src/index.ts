const RELEASE_PATH =
  /^\/releases\/(latest-(?:amd64|arm64)\.(?:tar\.gz|sha256))$/;

async function secureEqual(left: string, right: string | undefined): Promise<boolean> {
  if (!left || !right) return false;

  const encoder = new TextEncoder();
  const [leftHash, rightHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);

  const a = new Uint8Array(leftHash);
  const b = new Uint8Array(rightHash);
  let diff = a.length ^ b.length;

  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    diff |= (a[index] ?? 0) ^ (b[index] ?? 0);
  }

  return diff === 0;
}

function textResponse(
  message: string,
  status: number,
  headers?: HeadersInit,
): Response {
  const responseHeaders = new Headers(headers);
  responseHeaders.set("content-type", "text/plain; charset=utf-8");
  responseHeaders.set("cache-control", "no-store");
  responseHeaders.set("x-content-type-options", "nosniff");

  return new Response(`${message}\n`, {
    status,
    headers: responseHeaders,
  });
}

function bearerToken(request: Request): string {
  const authorization = request.headers.get("authorization") ?? "";
  const match = authorization.match(/^Bearer[ \t]+([^\s,]+)[ \t]*$/i);
  return match?.[1] ?? "";
}

function objectHeaders(
  object: R2Object,
  isPublic: boolean,
  downloadName: string | undefined,
): Headers {
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  headers.set("etag", object.httpEtag);
  headers.set("content-length", String(object.size));
  headers.set("x-content-type-options", "nosniff");
  headers.set(
    "cache-control",
    isPublic ? "public, max-age=300" : "private, no-store",
  );

  if (isPublic) {
    headers.set("content-type", "text/x-shellscript; charset=utf-8");
  } else if (downloadName) {
    headers.set("content-disposition", `attachment; filename="${downloadName}"`);
  }

  return headers;
}

async function handleRequest(request: Request, env: Env): Promise<Response> {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return textResponse("Method Not Allowed", 405, { allow: "GET, HEAD" });
  }

  const url = new URL(request.url);
  let objectKey: string;
  let isPublic = false;
  let downloadName: string | undefined;

  if (url.pathname === "/install.sh") {
    objectKey = "public/install.sh";
    isPublic = true;
  } else {
    const releaseMatch = url.pathname.match(RELEASE_PATH);
    if (!releaseMatch) {
      return textResponse("Not Found", 404);
    }

    if (!(await secureEqual(bearerToken(request), env.INSTALL_TOKEN))) {
      return textResponse("Unauthorized", 401, {
        "www-authenticate": "Bearer",
      });
    }

    downloadName = releaseMatch[1];
    objectKey = `releases/${downloadName}`;
  }

  if (request.method === "HEAD") {
    const object = await env.BUNDLES.head(objectKey);
    if (!object) {
      return textResponse("Object Not Found", 404);
    }
    return new Response(null, {
      status: 200,
      headers: objectHeaders(object, isPublic, downloadName),
    });
  }

  const object = await env.BUNDLES.get(objectKey);
  if (!object) {
    return textResponse("Object Not Found", 404);
  }

  return new Response(object.body, {
    status: 200,
    headers: objectHeaders(object, isPublic, downloadName),
  });
}

export default {
  async fetch(request, env): Promise<Response> {
    try {
      return await handleRequest(request, env);
    } catch (error) {
      console.error(
        JSON.stringify({
          message: "R2 download request failed",
          error: error instanceof Error ? error.message : String(error),
          method: request.method,
          path: new URL(request.url).pathname,
        }),
      );
      return textResponse("Internal Server Error", 500);
    }
  },
} satisfies ExportedHandler<Env>;
