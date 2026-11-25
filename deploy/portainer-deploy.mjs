import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, '..');

const envFilePath = path.join(rootDir, 'portainer.env');
const stackFilePath = path.join(rootDir, 'portainer-stack.yml');

if (!fs.existsSync(envFilePath)) {
  console.error(`[LOI] Khong tim thay file cau hinh: ${envFilePath}`);
  console.error(' -> Chay lenh sau tai thu muc goc roi dien token/secret:');
  console.error('    Copy-Item portainer.env.example portainer.env');
  process.exit(1);
}

if (!fs.existsSync(stackFilePath)) {
  console.error(`[LOI] Khong tim thay file compose stack: ${stackFilePath}`);
  process.exit(1);
}

const envRaw = fs.readFileSync(envFilePath, 'utf8');
const stackContent = fs.readFileSync(stackFilePath, 'utf8');

// Cac bien chi phuc vu may local di deploy — KHONG day len Portainer Stack runtime
const DEPLOY_ONLY_ENV_KEYS = new Set([
  'DOCKERHUB_TOKEN',
  'DOCKERHUB_USERNAME',
  'PORTAINER_ACCESS_TOKEN',
  'PORTAINER_URL',
  'PORTAINER_ENDPOINT_ID',
  'PORTAINER_STACK_ID',
  'PORTAINER_STACK_NAME',
  'SKIP_DOCKER_PUSH',
  'AUTO_PUSH_DOCKERHUB',
  'COMPOSE_PROJECT_NAME'
]);

const envMap = new Map();
const envList = [];
let skippedDeployOnlyCount = 0;

for (const line of envRaw.split(/\r?\n/)) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith('#')) continue;
  const eqIdx = trimmed.indexOf('=');
  if (eqIdx > 0) {
    const key = trimmed.slice(0, eqIdx).trim();
    let val = trimmed.slice(eqIdx + 1).trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    } else {
      const hashIdx = val.indexOf('#');
      if (hashIdx >= 0) {
        val = val.slice(0, hashIdx).trim();
      }
    }
    envMap.set(key, val);
    if (DEPLOY_ONLY_ENV_KEYS.has(key)) {
      skippedDeployOnlyCount += 1;
    } else if (val !== '') {
      envList.push({ name: key, value: val });
    }
  }
}

const portainerUrl = (envMap.get('PORTAINER_URL') || 'https://portainer.demego.vn').replace(/\/+$/, '');
const apiKey = envMap.get('PORTAINER_ACCESS_TOKEN');
const endpointId = Number(envMap.get('PORTAINER_ENDPOINT_ID') || 3);
let stackId = (envMap.get('PORTAINER_STACK_ID') || '').trim();
const stackName = (envMap.get('PORTAINER_STACK_NAME') || 'cli-proxy-api').trim();

const dockerImage =
  envMap.get('DOCKER_IMAGE') ||
  `${envMap.get('DOCKER_IMAGE_REPO') || 'dungnt118/freepbx'}:${envMap.get('DOCKER_IMAGE_TAG') || 'cli-proxy-api'}`;
const dockerUsername = envMap.get('DOCKERHUB_USERNAME') || 'dungnt118';
const dockerPassword = envMap.get('DOCKERHUB_TOKEN');

if (!apiKey) {
  console.error('[LOI] Khong tim thay PORTAINER_ACCESS_TOKEN trong file portainer.env!');
  process.exit(1);
}

console.log('=================================================================');
console.log('   CLIProxyAPI - Portainer Deploy Pipeline (Native REST API)');
console.log('=================================================================');
console.log(` - Server Portainer:  ${portainerUrl}`);
console.log(` - Stack Name:        ${stackName}${stackId ? ` (#${stackId})` : ' (tu dong tim / tao moi)'}`);
console.log(` - Endpoint ID:       ${endpointId}`);
console.log(` - Target Image:      ${dockerImage}`);
console.log(` - So bien moi truong: ${envList.length} (da loc ${skippedDeployOnlyCount} bien deploy-only)`);
console.log(` - Kich thuoc Stack:   ${stackContent.length} bytes`);
console.log('');

try {
  // TASK 1: PULL DOCKER IMAGE DOC LAP QUA PORTAINER DOCKER API
  console.log('=== TASK 1: PULL DOCKER IMAGE QUA PORTAINER DOCKER API ===');
  console.log(` -> Dang gui lenh Pull Image moi nhat ve host Portainer: ${dockerImage} ...`);
  const encodedImage = encodeURIComponent(dockerImage);
  const pullUrl = `${portainerUrl}/api/endpoints/${endpointId}/docker/images/create?fromImage=${encodedImage}`;
  const pullHeaders = {
    'X-API-Key': apiKey
  };

  if (dockerUsername && dockerPassword) {
    const authJson = JSON.stringify({
      username: dockerUsername,
      password: dockerPassword,
      serveraddress: 'https://index.docker.io/v1/'
    });
    pullHeaders['X-Registry-Auth'] = Buffer.from(authJson).toString('base64');
  }

  try {
    const pullRes = await fetch(pullUrl, {
      method: 'POST',
      headers: pullHeaders
    });

    if (pullRes.ok) {
      const pullStreamText = await pullRes.text();
      let hasStreamError = false;
      let streamErrorMessage = '';
      for (const line of pullStreamText.split(/\r?\n/)) {
        if (!line.trim()) continue;
        try {
          const evt = JSON.parse(line);
          if (evt.error || evt.errorDetail) {
            hasStreamError = true;
            streamErrorMessage = evt.error || evt.errorDetail?.message || 'Unknown error';
          }
        } catch {}
      }

      if (hasStreamError) {
        console.warn(`[CANH BAO] Docker daemon bao loi khi keo image: ${streamErrorMessage}`);
        console.warn(' -> Kiem tra lai DOCKERHUB_TOKEN hoac quyen truy cap repo tren DockerHub.');
      } else {
        console.log(`[OK] Da keo xong layer moi nhat cua image '${dockerImage}' ve host Portainer!`);
      }
    } else {
      const pullErr = await pullRes.text();
      console.warn(`[CANH BAO] Khong the pull image qua Docker API (HTTP ${pullRes.status}): ${pullErr}`);
      console.warn(' -> Tiep tuc thu cap nhat / tao Stack...');
    }
  } catch (pullEx) {
    console.warn(`[CANH BAO] Loi ngoai le khi gui lenh pull image: ${pullEx.message}`);
    console.warn(' -> Tiep tuc thu cap nhat / tao Stack...');
  }
  console.log('');

  // TASK 2: TIM / TAO HOAC REDEPLOY STACK TREN PORTAINER
  console.log('=== TASK 2: CAP NHAT / TAO STACK TREN PORTAINER ===');

  if (!stackId) {
    console.log(` -> Dang tim Stack '${stackName}' tren Portainer...`);
    const listRes = await fetch(`${portainerUrl}/api/stacks`, {
      method: 'GET',
      headers: { 'X-API-Key': apiKey }
    });
    if (!listRes.ok) {
      const errText = await listRes.text();
      console.error(`[LOI] Khong the lay danh sach Stack tu Portainer! HTTP ${listRes.status}: ${errText}`);
      process.exit(1);
    }
    const stacks = await listRes.json();
    const matched = Array.isArray(stacks)
      ? stacks.find((s) => s.Name === stackName && Number(s.EndpointId) === endpointId)
      : null;
    if (matched) {
      stackId = String(matched.Id);
      console.log(` -> Da tim thay Stack '${stackName}' (#${stackId}).`);
    }
  }

  if (stackId) {
    const getUrl = `${portainerUrl}/api/stacks/${stackId}?endpointId=${endpointId}`;
    const getRes = await fetch(getUrl, {
      method: 'GET',
      headers: { 'X-API-Key': apiKey }
    });

    if (!getRes.ok) {
      const errText = await getRes.text();
      console.error(`[LOI] Khong the lay thong tin Stack #${stackId} tu Portainer! HTTP ${getRes.status}: ${errText}`);
      process.exit(1);
    }

    const stackInfo = await getRes.json();
    console.log(` -> Stack hien tai: '${stackInfo.Name}' | Type: ${stackInfo.Type} | Status: ${stackInfo.Status}`);
    console.log(' -> Dang gui lenh cap nhat Stack len Portainer...');

    const putUrl = `${portainerUrl}/api/stacks/${stackId}?endpointId=${endpointId}`;
    const putPayload = {
      stackFileContent: stackContent,
      env: envList,
      prune: true,
      pullImage: false // Task 1 da pull image voi Registry Auth roi
    };

    const putRes = await fetch(putUrl, {
      method: 'PUT',
      headers: {
        'X-API-Key': apiKey,
        'Content-Type': 'application/json; charset=utf-8'
      },
      body: JSON.stringify(putPayload)
    });

    if (!putRes.ok) {
      const errBody = await putRes.text();
      console.error(`[LOI] Portainer tu choi cap nhat Stack! HTTP ${putRes.status}: ${errBody}`);
      process.exit(1);
    }

    const putData = await putRes.json();
    console.log('[OK] Portainer da cap nhat va redeploy Stack thanh cong!');
    console.log(
      ` -> Stack ID: ${putData.Id} | Status: ${putData.Status} | UpdateDate: ${new Date(putData.UpdateDate * 1000).toLocaleString('vi-VN')}`
    );
  } else {
    console.log(` -> Chua co Stack '${stackName}', dang tao Stack moi tren Portainer...`);
    const createUrl = `${portainerUrl}/api/stacks/create/standalone/string?endpointId=${endpointId}`;
    const createPayload = {
      name: stackName,
      stackFileContent: stackContent,
      env: envList
    };

    const createRes = await fetch(createUrl, {
      method: 'POST',
      headers: {
        'X-API-Key': apiKey,
        'Content-Type': 'application/json; charset=utf-8'
      },
      body: JSON.stringify(createPayload)
    });

    if (!createRes.ok) {
      const errBody = await createRes.text();
      console.error(`[LOI] Portainer tu choi tao Stack moi! HTTP ${createRes.status}: ${errBody}`);
      process.exit(1);
    }

    const createData = await createRes.json();
    console.log('[OK] Da tao moi va khoi chay Stack tren Portainer thanh cong!');
    console.log(` -> Stack ID: ${createData.Id} | Name: ${createData.Name} | Status: ${createData.Status}`);
    console.log(` -> Goi y: Ghi PORTAINER_STACK_ID=${createData.Id} vao file portainer.env cho cac lan deploy sau.`);
  }
} catch (err) {
  console.error(`[LOI] Qua trinh deploy Portainer gap loi ngoai le: ${err.message}`);
  process.exit(1);
}
