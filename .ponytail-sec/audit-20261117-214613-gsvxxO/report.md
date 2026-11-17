# Auditoría de seguridad — Lotus Tune 2.1.1

Sin escaneos anteriores. Hallazgos: 3 código, 1 dependencia, 7 seguridad (4 vulnerabilidades, 3 hardening).

## Paso 1 · Código

- C1: URL de actualización de Windows interpolada en PowerShell sin escapar (`src/updates.cpp:225`).
- C2: URLs de descarga pasadas a yt-dlp sin terminador `--` (`src/downloads.cpp:913,1408,2184`, `src/player.cpp:1030`).
- C3: cookies y tokens OAuth escritos con permisos 0644 (`tools/ytm_login.py:238`, `src/discordrpc.cpp:516`).

Resto de fuentes: limpio. TLS verificado (QSslSocket::VerifyPeer, QNetworkRequest por defecto), sin shell en QProcess, sin secretos en logs.

## Paso 2 · Dependencias

D1: versiones fijadas pero anticuadas (Gradle plugin 8.5.0, AndroidX core 1.10.1, aqtinstall 3.3.0). Se mantienen pinned; actualizar cuando se pueda reverificar el build.

## Paso 3 · Seguridad

| # | Clase | Valoración | Etapa | Ubicación | Hallazgo | Arreglo |
|---|-------|-----------|-------|-----------|----------|---------|
| S1 | Vulnerability | High (CVSS-B 8.1) | 3 Exec | `src/updates.cpp:146` | `curl | bash` sin verificar integridad | Descargar, verificar SHA256 fijado, ejecutar solo si coincide |
| S2 | Vulnerability | High (CVSS-B 7.8) | 4 Data | `android/lotus-tune.keystore` | Keystore y contraseña en el repo | Keystore fuera de git, misma clave en Secrets y toolchain local |
| S3 | Vulnerability | Medium (CVSS-B 6.2) | 4 Data | `tools/ytm_login.py:238` | Credenciales 0644 | umask 0077 + chmod 0600 |
| S4 | Vulnerability | Medium (CVSS-B 6.1) | 3 Exec | `src/updates.cpp:225` | URL interpolada en PowerShell y yt-dlp sin `--` | Validar https/github.com, añadir `--` |
| S5 | Hardening | Efficacy Medium | 2 Authz | `AndroidManifest.xml:103` | AudioService exportado | exported=false |
| S6 | Hardening | Efficacy Medium | 1 Trust | `AndroidManifest.xml:25` | WRITE_SECURE_SETTINGS declarado | Quitar permiso y código MIUI |
| S7 | Hardening | Efficacy Low | 4 Data | `AndroidManifest.xml:33` | allowBackup=true | allowBackup=false |

Vectores:
```
S1 CVSS-B 8.1  CVSS:4.0/AV:N/AC:H/AT:P/PR:L/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N
S2 CVSS-B 7.8  CVSS:4.0/AV:N/AC:L/AT:N/PR:L/UI:R/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N
S3 CVSS-B 6.2  CVSS:4.0/AV:L/AC:L/AT:N/PR:L/UI:N/VC:H/VI:N/VA:N/SC:N/SI:N/SA:N
S4 CVSS-B 6.1  CVSS:4.0/AV:N/AC:H/AT:P/PR:L/UI:N/VC:H/VI:H/VA:L/SC:N/SI:N/SA:N
```

## Estado de los arreglos

Los 7 hallazgos se corrigieron sin cambiar la clave de firma (S2) ni la experiencia de actualización (S1/S4). Verificado: 34 tests, build Android, APK con allowBackup=false / AudioService no exportado / sin WRITE_SECURE_SETTINGS, misma firma CN=Lotus Tune. Secrets configurados en GitHub Actions.
