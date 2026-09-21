// Copies the shared page logic next to main.js so it ships inside the packaged app.
const fs = require('fs');
const path = require('path');
const src = path.join(__dirname, '..', 'shared', 'bridge.js');
const dst = path.join(__dirname, 'bridge.js');
fs.copyFileSync(src, dst);
console.log('synced bridge.js (' + fs.statSync(dst).size + ' bytes)');
