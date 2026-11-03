#!/bin/sh
# Emula localmente um job do builds.sr.ht a partir do .build.yml:
#   - instala os "packages" do manifesto (apk, imagem Alpine);
#   - cria o usuário "build" e coloca o repositório em ~/<repo>, como o
#     sourcehut faz ao clonar (só arquivos versionados ou não ignorados);
#   - roda cada task com "sh -xe" a partir do ~, com as variáveis de "environment";
#   - pula as tasks em SRHT_SKIP (padrão: upload, para não publicar nada).
# Uso (dentro do contêiner, ver alvo "srht" do Makefile):
#   sh /src/scripts/srht-local.sh
set -e
MANIFEST=/src/.build.yml
REPO=${SRHT_REPO:-schardong.srht.site}
SKIP=${SRHT_SKIP:-upload}

apk add --no-cache -q python3 py3-yaml git tar

cat > /tmp/run.py <<'PY'
import os, subprocess, sys, yaml
cmd, path = sys.argv[1], sys.argv[2]
m = yaml.safe_load(open(path))
if cmd == "packages":
    print(" ".join(m.get("packages") or []))
    sys.exit()
skip = set(sys.argv[3].split(",")) if len(sys.argv) > 3 else set()
env = dict(os.environ)
env.update({k: str(v) for k, v in (m.get("environment") or {}).items()})
home = os.path.expanduser("~")
for task in m.get("tasks") or []:
    (name, script), = task.items()
    if name in skip:
        print(f"[#] task {name}: pulada", flush=True)
        continue
    print(f"[#] task {name}", flush=True)
    r = subprocess.run(["sh", "-xe", "-c", script], cwd=home, env=env)
    if r.returncode:
        sys.exit(f"[#] task {name}: FALHOU (código {r.returncode})")
print("[#] build OK", flush=True)
PY

for p in $(python3 /tmp/run.py packages "$MANIFEST"); do
  apk add --no-cache -q "$p" || echo "[#] aviso: pacote '$p' não instalado"
done

adduser -D build
mkdir -p "/home/build/$REPO"
git config --global --add safe.directory /src
(cd /src && git ls-files -z -co --exclude-standard \
   | tar --null --ignore-failed-read -T - -cf - 2>/dev/null) \
  | tar -xf - -C "/home/build/$REPO"
chown -R build:build /home/build

su - build -c "python3 /tmp/run.py tasks $MANIFEST $SKIP"

if [ -f /home/build/site.tar.gz ]; then
  rm -rf /out/site && mkdir -p /out/site
  cp /home/build/site.tar.gz /out/
  tar -xzf /home/build/site.tar.gz -C /out/site
  echo "[#] pacote: $(du -h /home/build/site.tar.gz | cut -f1), $(tar -tzf /home/build/site.tar.gz | wc -l) entradas"
fi
