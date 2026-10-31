/* Presentation only. Existing inputs, upload processing and save handlers stay authoritative. */
(()=>{'use strict';function boot(){
const $=id=>document.getElementById(id),panel=document.querySelector('[data-merchant-panel="appearance"]'),editor=panel?.querySelector('.mt-box'),source=$('storeCoverPreview');if(!panel||!editor||!source||$('appearanceLivePreview'))return;
const make=(tag,text,cls)=>{const n=document.createElement(tag);if(text)n.textContent=text;if(cls)n.className=cls;return n;};
const layout=make('div',null,'appearance-studio');editor.before(layout);layout.append(editor);editor.classList.add('appearance-editor');
const preview=make('details',null,'appearance-preview');preview.id='appearanceLivePreview';preview.open=true;const summary=make('summary');summary.append(make('span','Customer preview'));const state=make('span','Preview','appearance-preview-state');summary.append(state);preview.append(summary);
const card=make('article',null,'appearance-store-card'),cover=make('div',null,'appearance-store-cover');const coverHint=make('span','Your cover image'),coverEdit=make('button','Edit cover','appearance-edit-cover');coverEdit.type='button';cover.append(coverHint,coverEdit);
const content=make('div',null,'appearance-store-content'),identity=make('div',null,'appearance-store-identity'),logoBox=make('div',null,'appearance-store-logo'),logo=make('img'),initial=make('span'),identityText=make('div'),name=make('h3'),openState=make('span',null,'appearance-open-state');logo.alt='';logoBox.append(logo,initial);identityText.append(name,openState);identity.append(logoBox,identityText);
const tabs=make('div',null,'appearance-preview-tabs');tabs.setAttribute('aria-hidden','true');tabs.append(make('span','Menu/Items'),make('span','About'),make('span','Location'));
const tags=make('div',null,'appearance-store-tags'),description=make('p',null,'appearance-store-description'),address=make('p'),phone=make('p'),hours=make('p'),details=make('div',null,'appearance-store-details');details.append(address,phone,hours);
const edit=make('button','Edit store details','appearance-edit-details');edit.type='button';content.append(identity,tabs,tags,description,details,edit);card.append(cover,content);preview.append(card,make('p','Edits appear here. Save store appearance to publish.','appearance-preview-help'));layout.append(preview);
let dirty=false,logoSource='';
const focusField=id=>{const field=$(id);if(!field)return;for(let d=field.closest('details');d;d=d.parentElement?.closest('details'))d.open=true;field.scrollIntoView?.({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth',block:'center'});field.focus({preventScroll:true});};coverEdit.onclick=()=>focusField('storeCoverFile');edit.onclick=()=>focusField('storePhone');
$('dashboardLogoContainer')?.parentElement?.classList.add('portal-store-identity');$('portalTitle')?.parentElement?.classList.add('portal-store-heading');
const logoFallback=$('dashboardLogoContainer')?make('span',null,'portal-logo-fallback'):null;if(logoFallback)$('dashboardLogoContainer').append(logoFallback);
function update(){
 const category=typeof activeCategory!=='undefined'?activeCategory:'',vendor=typeof vendorData!=='undefined'?vendorData[category]:null,title=vendor?.name||category||'Your store',src=vendor?.logo||'';name.textContent=title;initial.textContent=title.trim().charAt(0);if(logoFallback)logoFallback.textContent=initial.textContent;
 if(src!==logoSource){logoSource=src;if(src)logo.src=src;else logo.removeAttribute('src');}logo.hidden=!src;initial.hidden=!!src;if(logoFallback)logoFallback.hidden=!!src;logo.onerror=()=>{logo.hidden=true;initial.hidden=false;};
 const background=source.style.backgroundImage||'';cover.style.backgroundImage=background;cover.classList.toggle('has-cover',!!background);coverHint.hidden=!!background;
 const show=(node,value,prefix='')=>{node.hidden=!value;node.textContent=value?prefix+value:'';};show(description,$('storeDescription')?.value.trim());show(address,$('storeAddress')?.value.trim());show(phone,$('storePhone')?.value.trim(),'Phone · ');
 const start=$('storeOpensAt')?.value,end=$('storeClosesAt')?.value;const time=value=>{if(!/^\d\d:\d\d$/.test(value||''))return '';const [h,m]=value.split(':').map(Number);return (h%12||12)+(m?':'+String(m).padStart(2,'0'):'')+(h<12?' AM':' PM');};show(hours,start&&end?time(start)+' – '+time(end)+' · Belize time':'');
 details.hidden=address.hidden&&phone.hidden&&hours.hidden;
 tags.replaceChildren(...[...panel.querySelectorAll('#storeTagPicker input:checked')].slice(0,3).map(i=>make('span',i.value)));tags.hidden=!tags.children.length;
 const status=$('statusTextLabel')?.textContent?.trim()||'';show(openState,/open/i.test(status)?'Open':/closed/i.test(status)?'Closed':'');openState.classList.toggle('is-closed',/closed/i.test(status));
 state.textContent=dirty?'Unsaved preview':/^Saved for /.test($('storeCoverStatus')?.textContent||'')?'Saved':'Preview';state.classList.toggle('is-dirty',dirty);
}
const change=e=>{if(e.target.matches('input,textarea,select')){dirty=true;update();}};panel.addEventListener('input',change);panel.addEventListener('change',change);$('storeCoverClear')?.addEventListener('click',()=>{dirty=true;update();});
new MutationObserver(update).observe(source,{attributes:true,attributeFilter:['style']});
new MutationObserver(()=>{const text=$('storeCoverStatus').textContent;if(/^Loading store appearance|^Public details|^Saved for /.test(text))dirty=false;else if(/^Preview ready|^Cover removed/.test(text))dirty=true;update();}).observe($('storeCoverStatus'),{childList:true,subtree:true,characterData:true});
for(const id of ['portalTitle','statusTextLabel','merchantWorkspaceDistrict']){const n=$(id);if(n)new MutationObserver(update).observe(n,{childList:true,subtree:true,characterData:true});}
const headerLogo=$('dashboardLogoImg');if(headerLogo){new MutationObserver(update).observe(headerLogo,{attributes:true,attributeFilter:['src']});headerLogo.addEventListener('error',()=>{headerLogo.style.display='none';if(logoFallback)logoFallback.hidden=false;});}
update();}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',boot);else boot();})();
