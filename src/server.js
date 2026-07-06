require('dotenv').config();

const express = require('express');
const { verifySignature } = require('./verifySignature');
const { handlePackageEvent } = require('./handlePackageEvent');

const PORT = Number(process.env.PORT) || 3000;
const WEBHOOK_SECRET = process.env.WEBHOOK_SECRET || '';

const app = express();

app.get('/health', (_req, res) => {
  res.json({ status: 'ok' });
});

function parsePayload(rawBody, contentType) {
  const bodyText = rawBody.toString('utf8');

  if (contentType.includes('application/x-www-form-urlencoded')) {
    const params = new URLSearchParams(bodyText);
    const payloadField = params.get('payload');

    if (!payloadField) {
      throw new Error('Missing payload field');
    }

    return JSON.parse(payloadField);
  }

  return JSON.parse(bodyText);
}

function handleWebhook(req, res) {
  const event = req.get('X-GitHub-Event') || 'unknown';
  const delivery = req.get('X-GitHub-Delivery') || 'unknown';
  const signature = req.get('X-Hub-Signature-256');
  const contentType = req.get('content-type') || '';

  if (!WEBHOOK_SECRET) {
    console.error('[webhook] WEBHOOK_SECRET is not configured');
    return res.status(500).send('Webhook secret not configured');
  }

  if (!verifySignature(req.body, signature, WEBHOOK_SECRET)) {
    console.warn(`[webhook] Invalid signature for delivery ${delivery}`);
    return res.status(401).send('Invalid signature');
  }

  let payload;
  try {
    payload = parsePayload(req.body, contentType);
  } catch {
    console.warn(`[webhook] Invalid payload for delivery ${delivery}`);
    return res.status(400).send('Invalid payload');
  }

  console.log(`[webhook] Received ${event} (delivery: ${delivery})`);

  if (event === 'ping') {
    console.log(`[webhook] Ping received for hook ${payload.hook_id}`);
    return res.status(200).send('pong');
  }

  if (event === 'package' || event === 'registry_package') {
    const result = handlePackageEvent(payload);
    return res.status(200).json({ ok: true, ...result });
  }

    return res.status(200).json({ ok: true, ignored: true, event });
  }

app.post(
  '/webhook/github',
  express.raw({
    type: ['application/json', 'application/x-www-form-urlencoded'],
  }),
  handleWebhook
);

app.listen(PORT, () => {
  console.log(`Webhook listener running on port ${PORT}`);
  console.log(`Webhook URL path: POST /webhook/github`);
});
