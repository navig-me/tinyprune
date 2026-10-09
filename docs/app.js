'use strict';
// Progressive enhancements only: the complete guide remains usable without JavaScript.
const motion = matchMedia('(prefers-reduced-motion: reduce)');
const icon = name => `<svg class="icon" aria-hidden="true"><use href="assets/icons.svg#${name}"></use></svg>`;
const status = document.createElement('p');
status.className = 'sr-only';
status.setAttribute('role', 'status');
status.setAttribute('aria-live', 'polite');
status.setAttribute('aria-atomic', 'true');
document.body.append(status);
let announcement;
function announce(message) {
  clearTimeout(announcement);
  status.textContent = '';
  announcement = setTimeout(() => { status.textContent = message; }, 40);
}
function enableCopy(control, text, message, label) {
  let reset;
  control.addEventListener('click', async event => {
    event.preventDefault();
    try {
      await navigator.clipboard.writeText(text());
      clearTimeout(reset);
      control.classList.add('copied');
      control.querySelector('use').setAttribute('href', 'assets/icons.svg#check');
      const caption = control.querySelector('.copy-label');
      if (caption) caption.textContent = 'Copied';
      announce(message);
      reset = setTimeout(() => {
        control.classList.remove('copied');
        control.querySelector('use').setAttribute('href', 'assets/icons.svg#copy');
        if (caption) caption.textContent = label;
      }, 2500);
    } catch {
      announce('Clipboard unavailable. Select and copy the text or use the address bar for a section link.');
    }
  });
}
document.querySelectorAll('pre').forEach(pre => {
  const code = pre.querySelector('code');
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'copy-button';
  button.setAttribute('aria-label', `Copy ${pre.getAttribute('aria-label') || 'code'}`);
  button.innerHTML = `${icon('copy')}<span class="copy-label">Copy</span>`;
  pre.classList.add('has-copy');
  pre.append(button);
  enableCopy(button, () => code.textContent, 'Copied', 'Copy');
});
// Existing section IDs remain canonical. Subheadings gain stable, readable deep links.
document.querySelectorAll('article h2, article h3').forEach(heading => {
  if (!heading.id) {
    const base = heading.tagName === 'H2' ? `${heading.closest('section').id}-title` : heading.textContent.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
    let id = base;
    let suffix = 2;
    while (document.getElementById(id)) id = `${base}-${suffix++}`;
    heading.id = id;
  }
  const link = document.createElement('a');
  link.className = 'heading-anchor';
  link.href = `#${heading.id}`;
  link.setAttribute('aria-label', `Copy link to ${heading.textContent}`);
  link.innerHTML = icon('copy');
  heading.append(link);
  enableCopy(link, () => new URL(link.getAttribute('href'), location.href).href, 'Copied section link', '');
});
const tableRegion = document.querySelector('#templates .table-wrap');
const rows = [...tableRegion.querySelectorAll('tbody tr')];
const searchRows = rows.map(row => ({row, text: row.textContent.toLowerCase()}));
const filter = document.createElement('div');
filter.className = 'template-filter';
filter.innerHTML = '<label for="template-search">Filter templates</label><input id="template-search" type="search" autocomplete="off" aria-controls="template-table" aria-describedby="template-count"><p class="filter-count" id="template-count" role="status" aria-live="polite" aria-atomic="true"></p>';
tableRegion.id = 'template-table';
tableRegion.before(filter);
const empty = document.createElement('p');
empty.className = 'template-empty';
empty.textContent = 'No templates match. Try a different name, folder, or tool.';
empty.hidden = true;
tableRegion.append(empty);
const count = filter.querySelector('.filter-count');
const input = filter.querySelector('input');
function filterTemplates() {
  const terms = input.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
  let matches = 0;
  searchRows.forEach(({row, text}) => {
    row.hidden = !terms.every(term => text.includes(term));
    if (!row.hidden) matches++;
  });
  count.textContent = `${matches} of ${rows.length} templates`;
  empty.hidden = matches !== 0;
  tableRegion.querySelector('table').hidden = matches === 0;
}
input.addEventListener('input', filterTemplates);
filterTemplates();
const guide = document.querySelector('.sidebar details');
const mobile = matchMedia('(max-width: 760px)');
const nav = guide.querySelector('nav');
const links = [...nav.querySelectorAll('a')];
const sections = links.map(link => document.querySelector(link.getAttribute('href')));
const indicator = document.createElement('span');
indicator.className = 'sidebar-indicator';
indicator.setAttribute('aria-hidden', 'true');
nav.append(indicator);
let active = links[0];
function positionIndicator() {
  if (mobile.matches || !guide.open) return;
  indicator.style.transform = `translateY(${active.offsetTop}px) scaleY(${active.offsetHeight})`;
}
function activate(link) {
  active = link;
  links.forEach(candidate => {
    if (candidate === link) candidate.setAttribute('aria-current', 'location');
    else candidate.removeAttribute('aria-current');
  });
  positionIndicator();
}
function adaptGuide() {
  guide.open = !mobile.matches;
  positionIndicator();
}
adaptGuide();
mobile.addEventListener('change', adaptGuide);
guide.addEventListener('toggle', positionIndicator);
links.forEach(link => link.addEventListener('click', () => {
  activate(link);
  if (mobile.matches) guide.open = false;
}));
activate(links.find(link => link.hash === location.hash) || links[0]);
if ('ResizeObserver' in window) new ResizeObserver(positionIndicator).observe(nav);
if ('IntersectionObserver' in window) {
  const visible = new Set();
  const spy = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (entry.isIntersecting) visible.add(entry.target);
      else visible.delete(entry.target);
    });
    const section = sections.find(candidate => visible.has(candidate));
    if (section) activate(links[sections.indexOf(section)]);
  }, {rootMargin: '-88px 0px -60% 0px', threshold: 0});
  sections.forEach(section => spy.observe(section));
  const reveal = new IntersectionObserver(entries => entries.forEach(entry => {
    if (!entry.isIntersecting) return;
    entry.target.classList.add('visible');
    reveal.unobserve(entry.target);
  }), {threshold: 0});
  document.querySelectorAll('article section').forEach(section => {
    section.classList.add('reveal');
    reveal.observe(section);
  });
  document.documentElement.classList.add('js');
  motion.addEventListener('change', () => {
    if (motion.matches) document.querySelectorAll('.reveal').forEach(section => {
      section.classList.add('visible');
      reveal.unobserve(section);
    });
  });
}
