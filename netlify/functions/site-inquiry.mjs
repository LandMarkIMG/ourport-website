import {validateInquiry} from '../../src/lib/inquiry.mjs';
const json=(status,body)=>new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
export const config={path:'/api/site-inquiry',rateLimit:{windowLimit:5,windowSize:60,aggregateBy:['ip','domain']}};
export function makeHandler({env=process.env,fetcher=fetch}={}){
  return async(request)=>{
    if(new URL(request.url).pathname!=='/api/site-inquiry')return json(404,{error:'Not found.'});
    if(request.method!=='POST')return json(405,{error:'Method not allowed.'});
    if(!env.SUPABASE_URL||!env.SUPABASE_SERVICE_ROLE_KEY||!env.ALLOWED_ORIGIN)return json(503,{error:'Inquiry storage is not connected. Please email Mike@Monetize-that.com.'});
    if(request.headers.get('origin')!==env.ALLOWED_ORIGIN)return json(403,{error:'Invalid origin.'});
    if(request.headers.get('content-type')?.split(';')[0].trim()!=='application/json')return json(415,{error:'JSON required.'});
    if(Number(request.headers.get('content-length'))>16384)return json(413,{error:'Inquiry too large.'});
    let body;
    try{const raw=await request.text();if(new TextEncoder().encode(raw).length>16384)return json(413,{error:'Inquiry too large.'});body=JSON.parse(raw);}catch{return json(400,{error:'Invalid inquiry.'});}
    const result=validateInquiry(body);if(result.error)return json(400,{error:result.error});
    try{
      const response=await fetcher(`${env.SUPABASE_URL.replace(/\/$/,'')}/rest/v1/site_inquiries?on_conflict=request_id`,{method:'POST',headers:{apikey:env.SUPABASE_SERVICE_ROLE_KEY,Authorization:`Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`,'Content-Type':'application/json',Prefer:'resolution=ignore-duplicates,return=minimal'},body:JSON.stringify(result.value),signal:AbortSignal.timeout(10000)});
      if(!response.ok)return json(502,{error:'Unable to save inquiry. Please retry.'});
      return json(201,{ok:true});
    }catch{return json(502,{error:'Unable to confirm receipt. Please retry.'});}
  };
}
export default makeHandler();
