#!/usr/bin/env bash
#
# cf-toggle.sh - Herramienta en Bash para automatizar la conmutación de registros DNS en Cloudflare
# entre Modo Proxy (Nube Naranja / proxied: true) y Modo Directo (Nube Gris / proxied: false).
#

set -euo pipefail

# --- Directorio y Funciones Helper ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "[%s] [%s] %s\n" "$timestamp" "$level" "$*"
}

usage() {
    cat <<EOF
Uso: $0 {on|off} [/ruta/al/archivo/.env]

Parámetros:
  on                Activa el proxy de Cloudflare (proxied: true - Nube Naranja)
  off               Desactiva el proxy de Cloudflare (proxied: false - Nube Gris)
  /ruta/.env        Ruta opcional al archivo .env (Por defecto: ${SCRIPT_DIR}/.env)

Ejemplos:
  $0 on
  $0 off /etc/cf-proxy-toggle/.env
EOF
    exit 1
}

# Procesamiento de respuestas JSON con jq
parse_json() {
    local filter="$1"
    local json_input="$2"
    if [[ -n "$json_input" ]]; then
        echo "$json_input" | jq -r "$filter" 2>/dev/null || echo ""
    fi
}

# Buscar Zone ID en la respuesta de zonas de Cloudflare usando jq
resolve_zone_id() {
    local domain="$1"
    local zones_response="$2"
    echo "$zones_response" | jq -r --arg dom "$domain" '
      [.result[]? | select($dom == .name or ($dom | endswith("." + .name)))]
      | sort_by(.name | length)
      | last
      | .id // ""
    ' 2>/dev/null || echo ""
}

# --- Validación de Argumentos ---
if [[ $# -lt 1 ]]; then
    log "ERROR" "Se requiere especificar una acción ({on|off})."
    usage
fi

ACTION="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
case "$ACTION" in
    on)
        TARGET_PROXIED="true"
        ACTION_NAME="ACTIVAR PROXY (proxied: true)"
        ;;
    off)
        TARGET_PROXIED="false"
        ACTION_NAME="DESACTIVAR PROXY (proxied: false)"
        ;;
    *)
        log "ERROR" "Acción no válida: '$1'. Debe ser 'on' u 'off'."
        usage
        ;;
esac

ENV_FILE="${2:-"${SCRIPT_DIR}/.env"}"

# --- Validación del Archivo de Entorno ---
if [[ ! -f "$ENV_FILE" ]]; then
    log "ERROR" "El archivo de configuración no existe: '$ENV_FILE'"
    exit 1
fi

if [[ ! -r "$ENV_FILE" ]]; then
    log "ERROR" "No se tienen permisos de lectura para el archivo: '$ENV_FILE'"
    exit 1
fi

# Cargar variables de entorno desde el archivo .env
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# --- Validación de Dependencias Estándar ---
for cmd in curl jq grep sed awk; do
    if ! command -v "$cmd" &>/dev/null; then
        log "ERROR" "Falta la dependencia requerida en el sistema: '$cmd'"
        exit 1
    fi
done

# --- Validación de Variables Obligatorias ---
MISSING_VARS=()
[[ -z "${CF_API_TOKEN:-}" ]] && MISSING_VARS+=("CF_API_TOKEN")
[[ -z "${CF_DOMAINS:-}" ]] && MISSING_VARS+=("CF_DOMAINS")

if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
    log "ERROR" "Faltan variables requeridas en el archivo .env: ${MISSING_VARS[*]}"
    exit 1
fi

log "INFO" "Iniciando conmutación: $ACTION_NAME"

# Obtener catálogo de Zonas desde Cloudflare API (para resolución automática de multi-dominio / multi-zona)
ZONES_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?per_page=100" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" || true)

# Procesar lista de dominios (separados por comas o espacios)
CLEAN_DOMAINS="$(echo "$CF_DOMAINS" | tr ',' ' ')"
read -r -a DOMAIN_ARRAY <<< "$CLEAN_DOMAINS"

# Limpiar CF_ZONE_ID si fue especificado manualmente
MANUAL_ZONE_IDS="$(echo "${CF_ZONE_ID:-}" | tr ',' ' ')"
read -r -a MANUAL_ZONE_ARRAY <<< "$MANUAL_ZONE_IDS"

HAS_ERRORS=0
SUCCESS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

for domain in "${DOMAIN_ARRAY[@]}"; do
    # Limpiar espacios en blanco adicionales
    domain="$(echo "$domain" | xargs)"
    [[ -z "$domain" ]] && continue

    log "INFO" "Procesando dominio: $domain"

    TARGET_ZONE_IDS=()

    # 1. Intentar resolver automáticamente la zona desde Cloudflare API usando jq
    AUTO_ZONE_ID=""
    if [[ -n "$ZONES_RESPONSE" ]]; then
        AUTO_ZONE_ID=$(resolve_zone_id "$domain" "$ZONES_RESPONSE")
    fi

    if [[ -n "$AUTO_ZONE_ID" ]]; then
        TARGET_ZONE_IDS+=("$AUTO_ZONE_ID")
    fi

    # 2. Agregar los Zone IDs manuales especificados en CF_ZONE_ID como respaldo
    for zid in "${MANUAL_ZONE_ARRAY[@]}"; do
        zid="$(echo "$zid" | xargs)"
        if [[ -n "$zid" && "$zid" != "$AUTO_ZONE_ID" ]]; then
            TARGET_ZONE_IDS+=("$zid")
        fi
    done

    if [[ ${#TARGET_ZONE_IDS[@]} -eq 0 ]]; then
        log "ERROR" "[$domain] No se pudo determinar el Zone ID (Especifícalo en CF_ZONE_ID o asegúrate de que el Token tenga permisos para leer zonas)."
        HAS_ERRORS=1
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    DOMAIN_FOUND_IN_ANY_ZONE=0

    for current_zone_id in "${TARGET_ZONE_IDS[@]}"; do
        # Consultar los registros DNS correspondientes en la zona
        DNS_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${current_zone_id}/dns_records?name=${domain}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" || true)

        if [[ -z "$DNS_RESPONSE" ]]; then
            continue
        fi

        IS_SUCCESS=$(parse_json ".success // false" "$DNS_RESPONSE")
        if [[ "$IS_SUCCESS" != "true" ]]; then
            continue
        fi

        RECORDS_COUNT=$(parse_json ".result | length" "$DNS_RESPONSE")
        [[ -z "$RECORDS_COUNT" ]] && RECORDS_COUNT=0

        if [[ "$RECORDS_COUNT" -eq 0 ]]; then
            continue
        fi

        DOMAIN_FOUND_IN_ANY_ZONE=1
        records_json=$(echo "$DNS_RESPONSE" | jq -c '.result[]' 2>/dev/null || echo "")

        while read -r record; do
            [[ -z "$record" ]] && continue

            RECORD_ID=$(parse_json ".id" "$record")
            RECORD_TYPE=$(parse_json ".type" "$record")
            RECORD_NAME=$(parse_json ".name" "$record")
            IS_PROXIABLE=$(parse_json ".proxiable // false" "$record")
            CURRENT_PROXIED=$(parse_json ".proxied // false" "$record")

            if [[ "$IS_PROXIABLE" != "true" ]]; then
                log "SKIP" "[$RECORD_NAME] Tipo $RECORD_TYPE no es proxiable (ID: $RECORD_ID)."
                SKIP_COUNT=$((SKIP_COUNT + 1))
                continue
            fi

            if [[ "$CURRENT_PROXIED" == "$TARGET_PROXIED" ]]; then
                log "SKIP" "[$RECORD_NAME] ($RECORD_TYPE) Ya tiene proxied=$TARGET_PROXIED."
                SKIP_COUNT=$((SKIP_COUNT + 1))
                continue
            fi

            # Petición PATCH para actualizar el estado del proxy
            PATCH_RESPONSE=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/${current_zone_id}/dns_records/${RECORD_ID}" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" \
                -H "Content-Type: application/json" \
                --data "{\"proxied\": ${TARGET_PROXIED}}" || true)

            PATCH_SUCCESS=$(parse_json ".success // false" "$PATCH_RESPONSE")

            if [[ "$PATCH_SUCCESS" == "true" ]]; then
                log "OK" "[$RECORD_NAME] ($RECORD_TYPE) Actualizado correctamente -> proxied=${TARGET_PROXIED}."
                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            else
                PATCH_ERR=$(parse_json ".errors[0].message // \"Fallo al realizar PATCH\"" "$PATCH_RESPONSE")
                [[ -z "$PATCH_ERR" ]] && PATCH_ERR="Error desconocido"
                log "ERROR" "[$RECORD_NAME] ($RECORD_TYPE) Error al actualizar: $PATCH_ERR"
                HAS_ERRORS=1
                FAIL_COUNT=$((FAIL_COUNT + 1))
            fi

        done <<< "$records_json"

        # Si encontramos registros en esta zona, no probamos más zonas para este dominio
        break
    done

    if [[ "$DOMAIN_FOUND_IN_ANY_ZONE" -eq 0 && ${#TARGET_ZONE_IDS[@]} -gt 0 ]]; then
        log "SKIP" "[$domain] No se encontraron registros DNS coincidentes en las zonas consultadas."
        SKIP_COUNT=$((SKIP_COUNT + 1))
    fi

done

# --- Ejecución del Servicio de Recarga (Si está definido) ---
if [[ -n "${RELOAD_SERVICE:-}" ]]; then
    log "INFO" "Ejecutando servicio/comando de recarga opcional: '$RELOAD_SERVICE'"
    if eval "$RELOAD_SERVICE"; then
        log "OK" "Comando de recarga completado exitosamente: '$RELOAD_SERVICE'"
    else
        log "ERROR" "Fallo al ejecutar comando de recarga: '$RELOAD_SERVICE'"
        HAS_ERRORS=1
    fi
fi

# --- Resultado y Código de Salida ---
log "INFO" "Resumen de ejecución | Éxitos: $SUCCESS_COUNT | Omitidos: $SKIP_COUNT | Errores: $FAIL_COUNT"

if [[ "$HAS_ERRORS" -ne 0 ]]; then
    log "ERROR" "La conmutación finalizó con uno o más errores."
    exit 1
else
    log "OK" "Conmutación completada exitosamente."
    exit 0
fi
