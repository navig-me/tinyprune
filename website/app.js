'use strict';
// Presentation-only simulation. No filesystem access or operational app state.
const motion = matchMedia('(prefers-reduced-motion: reduce)');
const finePointer = matchMedia('(hover: hover) and (pointer: fine)');
const sprite = name => `<svg class="icon" aria-hidden="true"><use href="#ph-${name}"></use></svg>`;
const command = 'brew install --cask navig-me/tap/tinyprune';
document.querySelectorAll('.copy-command').forEach(button => {
  let reset;
  button.addEventListener('click', async () => {
    const label = button.querySelector('.copy-label');
    try {
      await navigator.clipboard.writeText(command);
      button.classList.add('copied');
      button.querySelector('use').setAttribute('href', '#ph-check');
      label.textContent = 'Copied';
      if (!motion.matches) button.querySelector('.copy-feedback').animate([{transform:'scale(.8)'},{transform:'scale(1.12)'},{transform:'scale(1)'}],{duration:350});
      clearTimeout(reset);
      reset = setTimeout(() => { button.classList.remove('copied'); label.textContent = 'Copy'; button.querySelector('use').setAttribute('href','#ph-copy'); },2500);
    } catch { label.textContent = 'Retry'; button.setAttribute('aria-label','Clipboard unavailable. Select and copy the Homebrew command.'); }
  });
});
const tilt = document.querySelector('.tilt');
tilt.addEventListener('pointermove', event => {
  if (motion.matches || !finePointer.matches) return;
  const box = tilt.getBoundingClientRect();
  tilt.style.setProperty('--rx', `${-(event.clientY-box.top-box.height/2)/box.height*5}deg`);
  tilt.style.setProperty('--ry', `${(event.clientX-box.left-box.width/2)/box.width*5}deg`);
});
tilt.addEventListener('pointerleave', () => { tilt.style.setProperty('--rx','0deg'); tilt.style.setProperty('--ry','0deg'); });
document.querySelectorAll('.magnetic').forEach(button => {
  button.addEventListener('pointermove', event => {
    if (motion.matches || !finePointer.matches) return;
    const box = button.getBoundingClientRect();
    button.style.transform = `translate(${(event.clientX-box.left-box.width/2)*.1}px,${(event.clientY-box.top-box.height/2)*.15}px)`;
  });
  button.addEventListener('pointerleave', () => { button.style.transform = ''; });
});
if ('IntersectionObserver' in window) {
  document.documentElement.classList.add('js');
  const observer = new IntersectionObserver(entries => entries.forEach(entry => { if(entry.isIntersecting){entry.target.classList.add('visible');observer.unobserve(entry.target);} }),{threshold:.08});
  document.querySelectorAll('.reveal').forEach(section => observer.observe(section));
}
const samples = {
  downloads: {path:'~/Downloads',basis:'time in Downloads',files:[['installer.dmg',7],['editor.dmg',7],['assets.zip',14],['export.zip',14],['notes.pdf',30],['invoice.pdf',30],['mockup.png',30]]},
  screenshots: {path:'~/Desktop/Screenshots',basis:'time since creation',files:[['Screenshot 2026-10-01.png',7],['Screenshot 2026-10-02.png',7],['Screen Shot desktop.png',7],['Screenshot settings.png',7],['Screen Shot layout.png',7],['Screenshot reference.png',7]]},
  developer: {path:'~/Developer',basis:'project inactivity',files:[['site/node_modules',30],['site/node_modules/local.patch',30,'site/node_modules'],['api/.venv',45],['dashboard/node_modules',30],['tools/.venv',45],['archive/node_modules',30]]}
};
let state = {rule:'downloads',day:0,mode:'preview',kept:new Set()};
let selected = null;
let previousMoved = new Set();
let playing = false;
let animationFrame;
const range = document.getElementById('day');
const list = document.getElementById('file-list');
const bin = document.getElementById('trash-stage');
// Every row and Trash count is derived only from (rule, day, mode, kept).
function evaluateSample({rule,day,mode,kept}) {
  const sample = samples[rule];
  return sample.files.map(([name,deadline,parent]) => {
    const protectedByChild = sample.files.some(([child,,owner]) => owner === name && kept.has(child));
    const protectedByParent = parent && kept.has(parent);
    const protectedItem = kept.has(name) || protectedByChild || protectedByParent;
    const due = day >= deadline;
    const parentMoves = parent && !protectedItem && day >= deadline && mode === 'active';
    return {name,deadline,parent,protectedByChild,protectedByParent,protectedItem,due,moved:due && !protectedItem && mode === 'active',counted:due && !protectedItem && mode === 'active' && !parentMoves};
  });
}
function explain(file) {
  const rule = state.rule === 'downloads' ? (file.name.endsWith('.dmg')?'DMG':file.name.endsWith('.zip')?'ZIP':'Other downloads') : state.rule === 'screenshots' ? 'Screenshot filename' : file.name.includes('.venv') ? '.venv folder' : 'node_modules folder';
  const override = state.kept.has(file.name) ? 'Keep overrides this deadline.' : file.protectedByChild ? 'A kept descendant protects this entire folder.' : file.protectedByParent ? 'Its parent folder is marked Keep.' : 'No Keep override.';
  return `${file.name}: ${rule} rule, based on ${samples[state.rule].basis}. Deadline: day ${file.deadline}. ${override}${file.parent ? ' This item is inside a matched folder, not a separate cleanup candidate.' : ''}`;
}
function render(animate=true) {
  const files = evaluateSample(state);
  const moved = new Set(files.filter(file => file.moved).map(file => file.name));
  const newlyMoved = files.filter(file => file.moved && !previousMoved.has(file.name) && !file.parent);
  document.getElementById('folder-path').textContent = samples[state.rule].path;
  if (list.dataset.rule !== state.rule) {
    list.innerHTML = files.map((file,index) => `<button type="button" class="file-row" data-index="${index}">${sprite(file.parent?'file':state.rule==='developer'?'folder':'file')}<span class="file-name"></span><span class="file-state"></span><span class="lock-icon">${sprite('lock-simple-open')}</span></button>`).join('');
    list.dataset.rule=state.rule;
  }
  files.forEach((file,index) => {
    const row = list.children[index];
    row.querySelector('.file-name').textContent=file.name;
    row.querySelector('.file-state').textContent = file.protectedItem ? file.protectedByChild?'Kept descendant':'Keep' : file.moved ? file.parent?'In folder in Trash':'In Trash' : file.due ? file.parent?'Inside matched folder':'Would move' : `${file.deadline-state.day} days left`;
    row.classList.toggle('kept',!!file.protectedItem);
    row.classList.toggle('ghost',file.moved);
    row.classList.toggle('selected',selected===file.name);
    row.setAttribute('aria-pressed',state.kept.has(file.name)?'true':'false');
    row.setAttribute('aria-label',`${file.name}. ${row.querySelector('.file-state').textContent}. Toggle Keep.`);
    row.querySelector('.lock-icon use').setAttribute('href',`#ph-${file.protectedItem?'lock-simple':'lock-simple-open'}`);
  });
  const count = files.filter(file=>file.counted).length;
  document.getElementById('trash-count').textContent=count;
  document.getElementById('bin-note').textContent=state.mode==='preview'?'Preview never touches a file.':'Simulated moves to Trash. Scrub back to rewind.';
  document.getElementById('day-output').textContent=state.day;
  range.value=state.day;
  document.querySelector('.mode-switch').classList.toggle('active',state.mode==='active');
  document.querySelectorAll('[data-mode]').forEach(button=>button.setAttribute('aria-pressed',button.dataset.mode===state.mode));
  document.querySelectorAll('[data-rule]').forEach(button=>button.setAttribute('aria-pressed',button.dataset.rule===state.rule));
  const chosen=files.find(file=>file.name===selected);
  document.getElementById('why').textContent=chosen?explain(chosen):'Choose a file to see its rule, deadline and Keep override.';
  document.getElementById('summary').textContent=`Day ${state.day}, ${state.mode}. ${count} folders or files in simulated Trash. ${files.filter(file=>file.due&&!file.protectedItem&&!file.parent).length} due. ${state.kept.size} marked Keep.`;
  if (animate && !motion.matches && newlyMoved.length) {
    const target=bin.getBoundingClientRect();
    newlyMoved.forEach(file => {
      const row=list.children[files.indexOf(file)];
      const origin=row.getBoundingClientRect();
      const flying=row.cloneNode(true);
      flying.removeAttribute('aria-label');flying.setAttribute('aria-hidden','true');flying.tabIndex=-1;
      flying.style.cssText=`position:fixed;left:${origin.left}px;top:${origin.top}px;width:${origin.width}px;z-index:20;pointer-events:none;background:var(--surface)`;
      flying.classList.remove('ghost');document.body.append(flying);
      const animation=flying.animate([{transform:'translate(0,0) scale(1)',opacity:1},{transform:`translate(${target.left+target.width/2-origin.left-origin.width/2}px,${target.top+target.height/2-origin.top}px) scale(.15)`,opacity:0}],{duration:550,easing:'cubic-bezier(.4,0,.6,1)'});
      animation.finished.then(()=>flying.remove()).catch(()=>flying.remove());
    });
    bin.querySelector('.icon').animate([{transform:'scale(1)'},{transform:'translateY(5px) scale(1.1,.9)'},{transform:'translateY(-3px) scale(.96,1.04)'},{transform:'scale(1)'}],{duration:650});
  }
  previousMoved=moved;
}
list.addEventListener('click',event=>{
  const row=event.target.closest('.file-row');if(!row)return;
  const name=samples[state.rule].files[Number(row.dataset.index)][0];selected=name;
  const kept=new Set(state.kept);kept.has(name)?kept.delete(name):kept.add(name);state={...state,kept};render();
  if(!motion.matches)row.querySelector('.lock-icon').animate([{transform:'rotate(0)'},{transform:'rotate(-14deg) scale(1.15)'},{transform:'rotate(12deg)'},{transform:'rotate(0)'}],{duration:350});
});
function stopPlay(){playing=false;cancelAnimationFrame(animationFrame);document.getElementById('play').innerHTML=sprite('play')+'<span>Fast-forward</span>';}
range.addEventListener('input',()=>{stopPlay();state={...state,day:Number(range.value)};render();});
document.querySelectorAll('[data-rule]').forEach(button=>button.addEventListener('click',()=>{
  stopPlay();state={rule:button.dataset.rule,day:0,mode:'preview',kept:new Set()};selected=null;previousMoved=new Set();render(false);
  if (window.posthog) posthog.capture('example_selected', { label: button.getAttribute('data-rule') });
}));
document.querySelectorAll('[data-mode]').forEach(button=>button.addEventListener('click',()=>{state={...state,mode:button.dataset.mode};render();}));
document.getElementById('play').addEventListener('click',()=>{
  if(playing){stopPlay();return;}
  if(state.day===60){state={...state,day:0};render(false);}
  if(motion.matches){state={...state,day:60};render(false);return;}
  playing=true;document.getElementById('play').innerHTML=sprite('pause')+'<span>Pause</span>';
  const start=performance.now();const first=state.day;
  function tick(now){const progress=Math.min((now-start)/4500,1);const day=Math.round(first+(60-first)*(1-(1-progress)**2));if(day!==state.day){state={...state,day};render();}if(progress<1&&playing)animationFrame=requestAnimationFrame(tick);else stopPlay();}
  animationFrame=requestAnimationFrame(tick);
});
motion.addEventListener('change',()=>{stopPlay();document.querySelectorAll('.magnetic').forEach(button=>button.style.transform='');tilt.style.setProperty('--rx','0deg');tilt.style.setProperty('--ry','0deg');});
render(false);
const templates = [
  ['Downloads','~/Downloads','Top-level DMG, ZIP and other items','DMG 7 days; ZIP 14; other 30 days in folder','Active'],
  ['Screenshots','Chosen screenshot folder','Screenshot* and Screen Shot* filenames','7 days after creation','Active'],
  ['Temporary Workspace','Chosen disposable folder','Top-level items','3 days after first observation by default','Active'],
  ['Developer Cleanup','Chosen developer folder','Dependencies and build output; Python caches','Project inactivity; Python caches 7 days without modification','Preview'],
  ['Build Artifacts','Chosen project folder','dist, build, target, coverage, .cache folders','30 days of project inactivity','Preview'],
  ['Xcode Derived Data','~/Library/Developer/Xcode/DerivedData','Immediate child folders','60 days without modification','Preview'],
  ['Xcode Device Support','~/Library/Developer/Xcode/iOS DeviceSupport','Immediate child folders','180 days without modification','Preview'],
  ['Homebrew Downloads','~/Library/Caches/Homebrew/downloads','Completed hash-prefixed tar.gz, tar.xz, tar.bz2, ZIP, DMG and PKG files; incomplete downloads excluded','90 days without modification','Preview'],
  ['npm Cache','~/.npm/_cacache','Package cache files','90 days without modification','Preview'],
  ['Yarn Classic Cache','~/Library/Caches/Yarn','Yarn 1 cache files','90 days without modification','Preview'],
  ['pip Cache','~/Library/Caches/pip','HTTP and wheel cache files','90 days without modification','Preview'],
  ['Cargo Registry Cache','~/.cargo/registry/cache','.crate files only','90 days without modification','Preview'],
  ['Gradle Caches','~/.gradle/caches','Cache files only','90 days without modification','Preview']
];
const rail=document.getElementById('template-rail');
rail.innerHTML=templates.map(([name],index)=>`<button type="button" data-template="${index}" aria-pressed="${index===0}">${sprite(index<3?'folder':'terminal')}<span>${name}</span></button>`).join('');
function showTemplate(index,animate=true){
  const [name,...values]=templates[index];const receipt=document.getElementById('receipt');
  receipt.innerHTML=`<div><p class="receipt-label">Your rule receipt</p><h3>${name}</h3></div><dl>${['where','match','expires','starts in'].map((label,i)=>`<div><dt>${label}</dt><dd>${values[i]}</dd></div>`).join('')}</dl>`;
  rail.querySelectorAll('button').forEach((button,i)=>button.setAttribute('aria-pressed',i===index));
  if(animate&&!motion.matches)receipt.animate([{opacity:.3,transform:'translateY(4px)'},{opacity:1,transform:'translateY(0)'}],{duration:220});
}
rail.addEventListener('click',event=>{const button=event.target.closest('[data-template]');if(button)showTemplate(Number(button.dataset.template));});
showTemplate(0,false);
