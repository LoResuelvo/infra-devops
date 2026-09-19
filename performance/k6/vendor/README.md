# Dependencia vendorizada

[k6-reporter 3.0.4](https://github.com/benc-uk/k6-reporter/tree/3.0.4), licencia MIT.
Copia sin modificaciones de `dist/bundle.js`; licencia adjunta. No requiere npm
ni descargas durante una prueba. Se usa para el resumen HTML cuando el dashboard
nativo omite la exportación por falta de muestras (por ejemplo, un aborto temprano).

SHA-256 de `k6-reporter-3.0.4.js`:
`3d981a8f06dc558700e01e3fcbc3ab9214f4d45a4ff43c637c1ddf2e8d22c13c`

Al actualizar: descargar una versión explícita y su licencia, verificar el hash
y ejecutar las pruebas locales con k6 antes de usarla en staging.
