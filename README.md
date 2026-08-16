# Cloudflare DNS Proxy Toggle (`cf-proxy-toggle`)

Herramienta en Bash para automatizar la conmutación de registros DNS en Cloudflare entre **Modo Proxy** (Nube Naranja / `proxied: true`) y **Modo Directo** (Nube Gris / `proxied: false`) mediante la API v4 de Cloudflare.

Soporta **múltiples dominios y múltiples zonas DNS** simultáneamente con resolución automática de Zone IDs. Diseñado para ser ejecutado manualmente o mediante **Cron / Crontab**.

---

## 📋 Requisitos Previos

- **Linux** (con `bash`).
- **`curl`** para realizar peticiones HTTP/HTTPS.
- **`jq`** para el procesamiento de respuestas JSON.
- **`grep`**, **`sed`**, **`awk`** (herramientas estándar POSIX/Linux).
- **Token API de Cloudflare** con permisos de edición DNS (`Zone.DNS:Edit`) y opcionalmente lectura de zonas (`Zone.Zone:Read` para autodetección).

En sistemas basados en Debian/Ubuntu:
```bash
sudo apt update && sudo apt install -y curl jq
```

---

## 📁 Estructura del Proyecto

```text
cf-proxy-toggle/
├── cf-toggle.sh              # Script principal ejecutable
├── .env.example              # Plantilla de variables de entorno
├── .gitignore                # Reglas para ignorar .env y logs
└── README.md                 # Instrucciones de uso y despliegue
```

---

## ⚙️ Configuración (`.env`)

1. Copia la plantilla `.env.example` a `.env`:
   ```bash
   cp .env.example .env
   ```
2. Edita `.env` con tus credenciales y dominios:
   ```env
   # Token con permisos Zone.DNS:Edit
   CF_API_TOKEN="tu_token_aqui"

   # ID de la Zona en Cloudflare (Opcional: déjalo en blanco si tu Token puede leer las zonas)
   CF_ZONE_ID="89a9ca0ee4fa32bf2798fc0daa08dce4"

   # Lista de dominios/subdominios de cualquier zona que poseas
   CF_DOMAINS="midominio.com www.midominio.com otromidominio.es www.otromidominio.es"

   # Opcional: Comando para recargar o reiniciar un servicio tras el cambio
   RELOAD_SERVICE=""
   ```

---

## 🚀 Uso Manual

El script acepta dos argumentos:
```bash
./cf-toggle.sh {on|off} [/ruta/opcional/.env]
```

### Ejemplos:

- **Activar Modo Proxy (Nube Naranja):**
  ```bash
  ./cf-toggle.sh on
  ```

- **Desactivar Modo Proxy (Nube Gris / Directo):**
  ```bash
  ./cf-toggle.sh off
  ```

- **Especificar un archivo de configuración personalizado:**
  ```bash
  ./cf-toggle.sh off /etc/cf-proxy-toggle/.env
  ```

---

## ⏰ Automatización con Crontab

Para automatizar la conmutación periódica mediante `crontab`:

1. **Instalar el script ejecutable:**
   ```bash
   sudo cp cf-toggle.sh /usr/local/bin/cf-toggle.sh
   sudo chmod +x /usr/local/bin/cf-toggle.sh
   ```

2. **Crear directorio de configuración y copiar `.env`:**
   ```bash
   sudo mkdir -p /etc/cf-proxy-toggle
   sudo cp .env /etc/cf-proxy-toggle/.env
   sudo chmod 600 /etc/cf-proxy-toggle/.env
   ```

3. **Editar el Crontab (de root o tu usuario):**
   ```bash
   sudo crontab -e
   ```

4. **Añadir las siguientes tareas programadas:**
   ```cron
   # Apagar proxy Cloudflare (Nube Gris) los viernes a las 18:00
   0 18 * * 5 /usr/local/bin/cf-toggle.sh off /etc/cf-proxy-toggle/.env >> /var/log/cf-toggle.log 2>&1

   # Encender proxy Cloudflare (Nube Naranja) los lunes a las 02:00
   0 2 * * 1 /usr/local/bin/cf-toggle.sh on /etc/cf-proxy-toggle/.env >> /var/log/cf-toggle.log 2>&1
   ```

---

## 📜 Licencia

GNU General Public License v3.0 (GPL-3.0). Consulta el archivo [LICENSE](LICENSE) para más detalles.