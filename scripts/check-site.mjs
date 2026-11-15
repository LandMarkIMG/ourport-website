import {readFile,readdir,access} from 'node:fs/promises';
import {basename,extname,join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

const textExtensions=new Set(['.html','.htm','.js','.mjs','.cjs','.css','.json','.map','.svg','.txt','.xml','.webmanifest','.csv','.md','.yml','.yaml','.ts','.tsx','.jsx','.astro','.pem','.key']);
const textNames=new Set(['CNAME','_headers','_redirects']);

// Return categories only. Credential values must never enter validation output.
export function findSecretTypes(source){
  const types=[];
  if(/SUPABASE_SERVICE_ROLE_KEY|test-only-key/.test(source))types.push('server-only credential marker');
  if(/\bsb_secret_[A-Za-z0-9_-]+\b/.test(source))types.push('Supabase secret key');
  if(/-----BEGIN (?:(?:[A-Z0-9]+ )*PRIVATE KEY|PGP PRIVATE KEY BLOCK)-----/.test(source))types.push('private key block');
  for(const match of source.matchAll(/\beyJ[A-Za-z0-9_-]*\.([A-Za-z0-9_-]+)\.[A-Za-z0-9_-]+\b/g)){
    try{
      const payload=JSON.parse(Buffer.from(match[1],'base64url').toString('utf8'));
      if(payload?.role==='service_role'){
        types.push('Supabase service-role JWT');
        break;
      }
    }catch{
      // A malformed token is not a decoded credential; never print its contents.
    }
  }
  return types;
}

export async function checkSite(directory=resolve('dist')){
  const root=resolve(directory);
  const errors=[];
  let pages=0,links=0,textFiles=0;
  async function walk(dir){
    for(const item of await readdir(dir,{withFileTypes:true})){
      const p=join(dir,item.name);
      if(item.isDirectory()){
        await walk(p);
        continue;
      }
      const name=basename(p);
      const extension=extname(p).toLowerCase();
      if(!textExtensions.has(extension) && !textNames.has(name) && !name.startsWith('.env'))continue;
      const source=await readFile(p,'utf8');
      const reportPath=findSecretTypes(p).length?'[redacted credential-bearing filename]':p;
      textFiles++;
      for(const type of findSecretTypes(source))errors.push(`${reportPath}: ${type} found in public output`);
      if(extension!=='.html' && extension!=='.htm')continue;
      pages++;
      if((source.match(/<h1[ >]/g)||[]).length!==1)errors.push(`${reportPath}: expected one h1`);
      for(const match of source.matchAll(/(?:href|src)="(\/[^"#?]*)[^\"]*"/g)){
        links++;
        const reference=decodeURI(match[1]);
        const reportReference=findSecretTypes(reference).length?'[redacted credential-bearing reference]':match[1];
        let target=join(root,reference);
        if(match[1].endsWith('/'))target=join(target,'index.html');
        try{await access(target);}catch{errors.push(`${reportPath}: missing ${reportReference}`);}
      }
      for(const match of source.matchAll(/<img\b[^>]*>/g))if(!match[0].includes('alt='))errors.push(`${reportPath}: image without alt`);
    }
  }
  await walk(root);
  return {pages,links,textFiles,errors};
}

if(process.argv[1] && import.meta.url===pathToFileURL(resolve(process.argv[1])).href){
  const result=await checkSite();
  if(result.errors.length){
    console.error(result.errors.join('\n'));
    process.exitCode=1;
  }else{
    console.log(`${result.pages} pages checked; ${result.links} local references valid; one h1 per page; image alt text present; ${result.textFiles} public text files passed credential scan.`);
  }
}
