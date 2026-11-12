// The hero's entrance and the moments guard (taste kit), as a file so the page's CSP needs no inline script.
document.documentElement.classList.add('m-enter', 'mo-js');
setTimeout(() => document.documentElement.classList.add('m-enter-done'), 700);
setTimeout(() => document.documentElement.classList.add('mo-safe'), 2500);
