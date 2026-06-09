const PROJECT_ID = "bf2e00d3-d9a8-4ebc-9057-e2f34fe1bea5";
const API_BASE = "https://oein.fyi/api";

export type UpdateChannel = "release" | "beta" | "dev";

export const UPDATE_CHANNELS: { value: UpdateChannel; label: string }[] = [
  { value: "release", label: "Release (stable)" },
  { value: "beta", label: "Beta" },
  { value: "dev", label: "Dev (nightly)" },
];

export interface ReleaseFile {
  id: string;
  filename: string;
  size: number;
  mime_type: string;
  created_at: string;
}

export interface UpdateInfo {
  version: string;
  channel: UpdateChannel;
  description: string | null;
  files: ReleaseFile[];
}

function parseSemver(v: string): [number, number, number] {
  const parts = v.replace(/^v/, "").split(".").map(Number);
  return [parts[0] ?? 0, parts[1] ?? 0, parts[2] ?? 0];
}

function isNewer(remote: string, local: string): boolean {
  const [rMaj, rMin, rPatch] = parseSemver(remote);
  const [lMaj, lMin, lPatch] = parseSemver(local);
  if (rMaj !== lMaj) return rMaj > lMaj;
  if (rMin !== lMin) return rMin > lMin;
  return rPatch > lPatch;
}

export async function getCurrentVersion(): Promise<string> {
  try {
    const { getVersion } = await import("@tauri-apps/api/app");
    return await getVersion();
  } catch {
    return "0.0.0";
  }
}

function channelPath(channel: UpdateChannel): string {
  if (channel === "release") return "latest";
  if (channel === "beta") return "latest/beta";
  return "latest/dev";
}

export function fileDownloadUrl(version: string, fileId: string): string {
  return `${API_BASE}/projects/${PROJECT_ID}/versions/${encodeURIComponent(version)}/files/${fileId}`;
}

export function preferredFile(files: ReleaseFile[]): ReleaseFile | null {
  if (!files.length) return null;
  const ua = navigator.userAgent.toLowerCase();
  const isWindows = ua.includes("windows");
  const isMac = ua.includes("mac");
  for (const f of files) {
    const name = f.filename.toLowerCase();
    if (isWindows && (name.endsWith(".exe") || name.endsWith(".msi"))) return f;
    if (isMac && name.endsWith(".dmg")) return f;
    if (!isWindows && !isMac && name.endsWith(".appimage")) return f;
  }
  return files[0];
}

export async function fetchLatestUpdate(
  channel: UpdateChannel = "release",
): Promise<UpdateInfo | null> {
  const current = await getCurrentVersion();
  const path = channelPath(channel);
  const res = await fetch(
    `${API_BASE}/projects/${PROJECT_ID}/versions/${path}`,
  );
  if (!res.ok) return null;
  const data = await res.json();
  if (!isNewer(data.version as string, current)) return null;
  return {
    version: data.version as string,
    channel,
    description: (data.description as string | null) ?? null,
    files: (data.files ?? []) as ReleaseFile[],
  };
}
