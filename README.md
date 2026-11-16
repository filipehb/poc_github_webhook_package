# Webhook de deploy do checkin-discord-bot-v1

Serviço na droplet que recebe o webhook **Package** do GitHub e atualiza o bot.

O Nginx da droplet **já existe**. Ele só ganha um `location` novo. O bot em si não passa pelo Nginx: ele fala com o Discord de dentro da máquina.

```
tag no GitHub → imagem no GHCR → webhook → este serviço
→ MariaDB (se ainda não estiver no ar) → pull da imagem → recria só o app
```

O script usa o `compose.yml` da **raiz** do bot, o mesmo volume de banco de quem sobe com `docker compose` nessa pasta. Ele não usa o `deploy/docker-compose.yml` do bot, porque aquele arquivo também sobe o webhook em Go e cria outro volume.

## O que você precisa ter na droplet

- Docker e o plugin `docker compose`
- Node.js 20
- Nginx já instalado, com HTTPS no domínio que o GitHub vai chamar
- Git

Não instale outro Nginx.

## 1. Código do bot

```bash
sudo mkdir -p /opt/checkin-discord-bot-v1
sudo git clone https://github.com/Coletivo-Popular-Design-Desenvolvimento/checkin-discord-bot-v1.git /opt/checkin-discord-bot-v1
```

Se a pasta já existir, só atualize:

```bash
sudo git -C /opt/checkin-discord-bot-v1 pull
```

Crie `/opt/checkin-discord-bot-v1/.env`. A senha entra escrita por extenso. O Docker não expande `${DB_PASSWORD}` dentro do `DATABASE_URL`.

```env
TOKEN_BOT=cole-o-token-do-discord
PORT=3000

DB_HOST=db
DB_PORT=3306
DB_PASSWORD=uma-senha-forte
DB_DATABASE=checkindb

DATABASE_URL=mysql://root:uma-senha-forte@db:3306/checkindb
```

`DB_HOST` tem que ser `db`. É o nome do serviço no `compose.yml`. `localhost` não alcança o MariaDB de dentro do container.

## 2. Listener

```bash
sudo git clone https://github.com/filipehb/poc_github_webhook_package.git /opt/github-webhook
cd /opt/github-webhook
sudo npm ci
sudo cp .env.example .env
sudo nano .env
sudo chmod +x scripts/deploy-container.sh
```

No `.env` deste serviço:

- `WEBHOOK_SECRET`: o mesmo secret do webhook no GitHub
- `IMAGE_TAG=latest` em produção, ou `homol` em homologação
- `DOCKER_IMAGE` com a mesma tag
- `GHCR_USERNAME` e `GHCR_TOKEN` só se o pacote for privado (token com `read:packages`)

```bash
sudo useradd --system --home /opt/github-webhook --shell /usr/sbin/nologin webhook || true
sudo usermod -aG docker webhook
sudo chown -R webhook:webhook /opt/github-webhook

sudo chgrp webhook /opt/checkin-discord-bot-v1/.env
sudo chmod 640 /opt/checkin-discord-bot-v1/.env
sudo chmod 755 /opt/checkin-discord-bot-v1

sudo cp deploy/webhook.service /etc/systemd/system/github-webhook.service
sudo systemctl daemon-reload
sudo systemctl enable --now github-webhook
```

O listener escuta só em `127.0.0.1:3000`.

## 3. Nginx que já está na máquina

Abra o `server { }` que já tem o certificado do domínio. Cole o conteúdo de `deploy/nginx-location.conf`:

```nginx
location /webhook/github {
    proxy_pass http://127.0.0.1:3000;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    client_max_body_size 2m;
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

## 4. Primeira subida do bot

Rode o mesmo script que o webhook vai chamar depois:

```bash
sudo -u webhook -H bash -c 'set -a; source /opt/github-webhook/.env; set +a; bash /opt/github-webhook/scripts/deploy-container.sh'
```

O script faz, nesta ordem:

1. Confere `TOKEN_BOT`, `DB_PASSWORD`, `DB_HOST=db` e um `DATABASE_URL` sem `${...}`
2. Entra no GHCR se houver token
3. Para o container `checkin-webhook` se o webhook Go antigo ainda existir
4. Sobe o MariaDB **sem** recriar o volume que já existe
5. Espera o banco ficar healthy e cria `checkindb` se ainda não existir
6. Faz pull da imagem e recria **só** o serviço `app`
7. Espera cerca de 90 segundos. Se o container cair, o script termina com erro e mostra os logs

A imagem usada é a do `compose.yml` mais `deploy/checkin-image.override.yml`. O `compose.override.yml` de desenvolvimento (phpMyAdmin, porta do banco, nodemon) não entra.

Acompanhe:

```bash
sudo -u webhook tail -f /opt/github-webhook/logs/deploy.log
sudo docker logs -f node_app
```

## 5. Webhook no GitHub

No repositório **checkin-discord-bot-v1 → Settings → Webhooks**:

| Campo | Valor |
|-------|--------|
| Payload URL | `https://SEU_DOMINIO/webhook/github` |
| Content type | `application/json` |
| Secret | o mesmo `WEBHOOK_SECRET` |
| Events | Package (ou Registry packages) |

O ping tem que responder 200. Confira em Recent Deliveries.

Publicar uma versão nova continua sendo uma tag semver no bot:

```bash
git tag 1.0.0
git push origin 1.0.0
```

| Branch do commit | Tags no GHCR |
|------------------|--------------|
| `main` | `1.0.0` e `latest` |
| `homol` | `1.0.0-homol` e `homol` |

Com `IMAGE_TAG=latest`, só a tag `latest` dispara o deploy. A tag numérica `1.0.0` é ignorada de propósito.

## 6. Conferir

Na droplet:

```bash
curl -s http://127.0.0.1:3000/health
sudo journalctl -u github-webhook -f
```

No GitHub, a entrega do evento `package` deve voltar 200. O log do listener aponta para `logs/deploy.log`. O container `node_app` precisa continuar `running`.

## O que não fazer

- Não copie um compose por cima do `compose.yml` do bot.
- Não suba o serviço `webhook` do `deploy/docker-compose.yml` do bot. Este listener substitui ele.
- Não publique a porta do MariaDB. O `compose.override.yml` do bot faz isso só no desenvolvimento.
- Não mude o nome da pasta `/opt/checkin-discord-bot-v1` depois da primeira subida. O volume do banco usa esse nome.

## Se algo falhar

| Log | Causa |
|-----|--------|
| `DATABASE_URL precisa estar escrita por extenso` | Troque `${DB_PASSWORD}` pela senha real |
| `DB_HOST ... precisa ser db` | Dentro do container o banco se chama `db` |
| `não alcança o Docker` | `SupplementaryGroups=docker` no systemd e `systemctl restart github-webhook` |
| `pull access denied` | Pacote privado: preencha `GHCR_USERNAME` e `GHCR_TOKEN` |
| Bot sobe e cai | `docker logs --tail 80 node_app` — em geral token, senha ou migration |
| Dois bancos | Alguém subiu o `deploy/docker-compose.yml` do bot. O volume certo é o do `compose.yml` da raiz |
