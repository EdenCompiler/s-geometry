/* Valida recursos exportados com o verificador oficial da Khronos. */
const fs = require('node:fs/promises');
const path = require('node:path');
const validator = require('../.cache/gltf-validator/node_modules/gltf-validator');

(async () => {
  if (process.argv.length < 3) throw new Error('Informe um ou mais arquivos glTF/GLB.');
  for (const filename of process.argv.slice(2)) {
    const fullpath = path.resolve(filename);
    const report = await validator.validateBytes(new Uint8Array(await fs.readFile(fullpath)), {
      uri: path.basename(fullpath),
      maxIssues: 1000,
      externalResourceFunction: uri => fs.readFile(path.resolve(path.dirname(fullpath), decodeURIComponent(uri)))
    });
    await fs.writeFile(`${fullpath}.report.json`, JSON.stringify(report, null, 2));
    console.log(`${filename}: ${report.issues.numErrors} erros, ${report.issues.numWarnings} avisos`);
    if (report.issues.numErrors) {
      console.error(JSON.stringify(report.issues.messages, null, 2));
      process.exitCode = 1;
    }
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
