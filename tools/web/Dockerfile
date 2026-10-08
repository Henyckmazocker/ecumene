# Ecúmene — imagen estática de la build web para el homelab.
# Se construye desde la RAÍZ del repo (el compose pone context: ../..) para poder copiar
# builds/web/, que es la salida de `tools/export.sh web` (release, con la clave de Augur ya
# dentro del .pck: aquí no se añade nada). El .dockerignore de la raíz deja pasar solo
# builds/web/ y tools/web/.
FROM nginx:alpine

# Configuración propia en lugar de la por defecto: caché por tipo de fichero y compresión.
COPY tools/web/nginx.conf /etc/nginx/conf.d/default.conf

# Fuera lo que trae la imagen (index.html y 50x.html de bienvenida) para que no se cuele nada.
RUN rm -rf /usr/share/nginx/html/*
COPY builds/web/ /usr/share/nginx/html/

# Precomprimidos para gzip_static: se comprime una vez aquí y no en cada petición.
# -k conserva el original, que es el que reciben los clientes sin gzip.
RUN cd /usr/share/nginx/html \
 && gzip -k -9 index.html index.js index.pck index.wasm index.audio.worklet.js index.audio.position.worklet.js
