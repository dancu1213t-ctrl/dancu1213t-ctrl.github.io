const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(process.argv[2]||'.');let checked=0;
for(const name of fs.readdirSync(root)){if(!name.endsWith('.js'))continue;const s=fs.readFileSync(path.join(root,name),'utf8');if(/^\s*import\s/m.test(s)||/^\s*export\s/m.test(s))new vm.SourceTextModule(s,{identifier:name});else new vm.Script(s,{filename:name});checked++;}
const html=fs.readFileSync(path.join(root,'index.html'),'utf8');for(const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)){if(/\bsrc\s*=/.test(m[1])||/application\/(json|ld\+json)|importmap/.test(m[1]))continue;if(/type\s*=\s*["']module/.test(m[1]))new vm.SourceTextModule(m[2]);else new vm.Script(m[2]);checked++;}
for(const asset of ['release-health.js','release-health.css','support-requests.js','support-requests.css'])assert.ok(fs.existsSync(path.join(root,asset)),asset+' missing');
assert.equal(JSON.parse(fs.readFileSync(path.join(root,'build.json'))).version,'reliability20261028b');
console.log('PASS: '+checked+' scripts parse and release assets exist.');
