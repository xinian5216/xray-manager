import { env, exports } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";

async function fetchWorker(path: string, init?: RequestInit): Promise<Response> {
  return exports.default.fetch(`https://worker.example${path}`, init);
}

beforeEach(async () => {
  await Promise.all([
    env.BUNDLES.put("public/install.sh", "#!/usr/bin/env bash\necho ok\n", {
      httpMetadata: { contentType: "text/plain" },
    }),
    env.BUNDLES.put("releases/latest-amd64.tar.gz", "amd64-bundle", {
      httpMetadata: { contentType: "application/gzip" },
    }),
    env.BUNDLES.put("releases/latest-amd64.sha256", "deadbeef\n", {
      httpMetadata: { contentType: "text/plain" },
    }),
    env.BUNDLES.put("releases/manifest.json", '{"format":1}\n', {
      httpMetadata: { contentType: "application/json" },
    }),
  ]);
});

describe("xray-manager download Worker", () => {
  it("serves the public installer without authentication", async () => {
    const response = await fetchWorker("/install.sh");

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe(
      "text/x-shellscript; charset=utf-8",
    );
    expect(response.headers.get("cache-control")).toBe("public, max-age=300");
    expect(await response.text()).toContain("echo ok");
  });

  it("serves HEAD metadata without a response body", async () => {
    const response = await fetchWorker("/install.sh", { method: "HEAD" });

    expect(response.status).toBe(200);
    expect(response.headers.get("content-length")).toBe("28");
    expect(await response.text()).toBe("");
  });

  it("rejects protected objects without the install token", async () => {
    const response = await fetchWorker("/releases/latest-amd64.tar.gz");

    expect(response.status).toBe(401);
    expect(response.headers.get("www-authenticate")).toBe("Bearer");
    expect(response.headers.get("cache-control")).toBe("no-store");
  });

  it("accepts a case-insensitive Bearer scheme and streams the object", async () => {
    const response = await fetchWorker("/releases/latest-amd64.tar.gz", {
      headers: { authorization: "bearer test-install-token" },
    });

    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/gzip");
    expect(response.headers.get("cache-control")).toBe("private, no-store");
    expect(response.headers.get("content-disposition")).toBe(
      'attachment; filename="latest-amd64.tar.gz"',
    );
    expect(new TextDecoder().decode(await response.arrayBuffer())).toBe(
      "amd64-bundle",
    );
  });

  it("only permits the fixed release object names", async () => {
    const response = await fetchWorker("/releases/v1.2.3-amd64.tar.gz", {
      headers: { authorization: "Bearer test-install-token" },
    });

    expect(response.status).toBe(404);
  });

  it("serves the overwrite-in-place publish manifest", async () => {
    const response = await fetchWorker("/releases/manifest.json", {
      headers: { authorization: "Bearer test-install-token" },
    });

    expect(response.status).toBe(200);
    expect(await response.text()).toContain('"format":1');
  });

  it("returns 405 and an Allow header for unsupported methods", async () => {
    const response = await fetchWorker("/install.sh", { method: "POST" });

    expect(response.status).toBe(405);
    expect(response.headers.get("allow")).toBe("GET, HEAD");
  });

  it("returns 404 when an allowed R2 object does not exist", async () => {
    const response = await fetchWorker("/releases/latest-arm64.sha256", {
      headers: { authorization: "Bearer test-install-token" },
    });

    expect(response.status).toBe(404);
    expect(await response.text()).toBe("Object Not Found\n");
  });
});
