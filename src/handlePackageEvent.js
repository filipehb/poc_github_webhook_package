const { spawn } = require('child_process');
const path = require('path');

const DEPLOY_ACTIONS = new Set(['published', 'updated']);
const CONTAINER_TYPES = new Set(['container', 'docker']);

function getConfig() {
  return {
    packageOwner: process.env.PACKAGE_OWNER || '',
    packageName: process.env.PACKAGE_NAME || '',
    imageTag: process.env.IMAGE_TAG || '',
    composeFile: process.env.COMPOSE_FILE || '',
    containerName: process.env.CONTAINER_NAME || '',
  };
}

function getPackageData(payload) {
  return payload.package || payload.registry_package || null;
}

function isContainerPackage(packageType) {
  if (!packageType) {
    return false;
  }

  return CONTAINER_TYPES.has(String(packageType).toLowerCase());
}

function getPackageOwner(payload, pkg) {
  return pkg?.owner?.login || payload.organization?.login || '';
}

function getPackageName(pkg) {
  return pkg?.name || '';
}

function looksLikeDigest(value) {
  return /^sha256:[a-f0-9]+$/i.test(value);
}

function getPackageTag(pkg) {
  const tagFromMetadata = pkg?.package_version?.container_metadata?.tag?.name;
  if (tagFromMetadata) {
    return tagFromMetadata;
  }

  const packageUrl = pkg?.package_version?.package_url || '';
  if (packageUrl.includes(':')) {
    const tag = packageUrl.split(':').pop();
    if (tag && !looksLikeDigest(tag)) {
      return tag;
    }
  }

  const fallback = pkg?.package_version?.name || pkg?.package_version?.version || '';
  if (fallback && !looksLikeDigest(fallback)) {
    return fallback;
  }

  return '';
}

function buildImageRef(owner, name, tag) {
  return `ghcr.io/${owner}/${name}:${tag}`;
}

function matchesFilter(value, filter) {
  if (!filter) {
    return true;
  }

  if (filter.includes('*')) {
    const pattern = new RegExp(`^${filter.replace(/\*/g, '.*')}$`);
    return pattern.test(value);
  }

  return value === filter;
}

function shouldDeploy(payload) {
  const config = getConfig();
  const pkg = getPackageData(payload);
  const action = payload.action;

  if (!pkg) {
    return { deploy: false, reason: 'Missing package data in payload' };
  }

  if (!DEPLOY_ACTIONS.has(action)) {
    return { deploy: false, reason: `Ignoring action: ${action}` };
  }

  const packageType = pkg.package_type;
  if (!isContainerPackage(packageType)) {
    return {
      deploy: false,
      reason: `Ignoring package type: ${packageType ?? 'undefined'}`,
    };
  }

  const owner = getPackageOwner(payload, pkg);
  const name = getPackageName(pkg);
  const tag = getPackageTag(pkg);

  if (!owner || !name || !tag) {
    const manifestType =
      pkg?.package_version?.container_metadata?.manifest?.media_type || '';
    const isManifestOnly =
      manifestType.includes('image.index') || looksLikeDigest(tag);

    return {
      deploy: false,
      reason: isManifestOnly
        ? 'Skipping per-arch/manifest webhook (no image tag)'
        : `Missing package details (owner=${owner || 'n/a'}, name=${name || 'n/a'}, tag=${tag || 'n/a'})`,
    };
  }

  if (!matchesFilter(owner, config.packageOwner)) {
    return { deploy: false, reason: `Owner ${owner} does not match filter` };
  }

  if (!matchesFilter(name, config.packageName)) {
    return { deploy: false, reason: `Package ${name} does not match filter` };
  }

  if (!matchesFilter(tag, config.imageTag)) {
    return { deploy: false, reason: `Tag ${tag} does not match filter` };
  }

  return {
    deploy: true,
    image: buildImageRef(owner, name, tag),
    owner,
    name,
    tag,
  };
}

function runDeployScript(image) {
  const scriptPath = path.join(__dirname, '..', 'scripts', 'deploy-container.sh');
  const config = getConfig();

  const env = {
    ...process.env,
    IMAGE: image,
    COMPOSE_FILE: config.composeFile,
    CONTAINER_NAME: config.containerName,
  };

  const child = spawn('bash', [scriptPath], {
    env,
    detached: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  child.stdout.on('data', (data) => {
    process.stdout.write(`[deploy] ${data}`);
  });

  child.stderr.on('data', (data) => {
    process.stderr.write(`[deploy] ${data}`);
  });

  child.on('error', (error) => {
    console.error('[deploy] Failed to start deploy script:', error.message);
  });

  child.on('close', (code) => {
    if (code === 0) {
      console.log(`[deploy] Completed successfully for ${image}`);
    } else {
      console.error(`[deploy] Exited with code ${code} for ${image}`);
    }
  });

  child.unref();
}

function handlePackageEvent(payload) {
  const decision = shouldDeploy(payload);

  if (!decision.deploy) {
    console.log(`[package] Skipped: ${decision.reason}`);
    return { triggered: false, reason: decision.reason };
  }

  console.log(
    `[package] Triggering deploy for ${decision.image} (${payload.action})`
  );
  runDeployScript(decision.image);

  return {
    triggered: true,
    image: decision.image,
    action: payload.action,
  };
}

module.exports = {
  handlePackageEvent,
  shouldDeploy,
  buildImageRef,
  getPackageData,
  isContainerPackage,
};
