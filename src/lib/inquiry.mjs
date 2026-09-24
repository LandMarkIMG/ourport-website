const common={contactName:120,email:254,projectName:180,location:180,currentService:180,note:2000,sourcePath:180};
const branches={laundromat:{dashboard:180,processingHours:180,accessHours:180,bagSize:300},housing:{providerStatus:180,residentSystem:180},builder:{siteStage:180,wallDimensions:200,siteConstraints:1000}};
export function validateInquiry(input){
  if(!input||typeof input!=='object'||Array.isArray(input))return{error:'Invalid inquiry.'};
  if(input.website)return{error:'Unable to accept this inquiry.'};
  if(!Object.hasOwn(branches,input.role))return{error:'Choose a project type.'};
  if(typeof input.requestId!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(input.requestId))return{error:'Invalid inquiry identifier.'};
  const data={role:input.role};
  for(const [key,max] of Object.entries({...common,...branches[input.role]})){
    if(input[key]===undefined||input[key]==='')continue;
    if(typeof input[key]!=='string'||input[key].length>max)return{error:`Invalid ${key}.`};
    const value=input[key].trim();if(value)data[key]=value;
  }
  if(!data.contactName||!data.location||!data.email||!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(data.email))return{error:'Name, valid email and location are required.'};
  for(const [key,max] of Object.entries({locationCount:10000,...(input.role==='housing'?{homesOrBeds:100000}:{})})){
    if(input[key]===undefined||input[key]==='')continue;
    if(!['string','number'].includes(typeof input[key]))return{error:`Invalid ${key}.`};
    const value=Number(input[key]);if(!Number.isSafeInteger(value)||value<1||value>max)return{error:`Invalid ${key}.`};data[key]=value;
  }
  return {value:{request_id:input.requestId,role:data.role,contact_name:data.contactName,contact_email:data.email,project_name:data.projectName||null,location:data.location,location_count:data.locationCount||null,details:Object.fromEntries(Object.entries(data).filter(([k])=>!['role','contactName','email','projectName','location','locationCount'].includes(k)))}};
}
