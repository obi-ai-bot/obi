// obi-sphere's server declares >=22.18; the pinned pnpm also needs >=22.13.
export const MIN_NODE_VERSION = "22.18";

export function requireNodeVersion(version) {
  const [major, minor] = version.split(".").map(Number);
  if (!(major > 22 || (major === 22 && minor >= 18))) {
    throw new Error(`Node ${version}; the harness and obi-sphere need ${MIN_NODE_VERSION} or later`);
  }
}
