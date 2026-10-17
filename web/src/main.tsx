import { StrictMode, useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter, Link, NavLink, Route, Routes, useLocation } from 'react-router-dom';
import './styles.css';

const pages = [
  { path: '/', label: 'Home', title: 'A little more peace of mind.', description: 'A quiet place to check on your home and the things that matter.', empty: 'Waiting for your rover', detail: 'Rover status, your current task, and the latest briefing will appear here when a connection is available.' },
  { path: '/changes', label: 'Changes', title: 'What changed at home', description: 'See what is different from one patrol to the next.', empty: 'No changes to show yet', detail: 'When patrol observations are connected, this space will show changes with their location and severity.' },
  { path: '/map', label: 'Map', title: 'A familiar place, mapped.', description: 'Find your bearings in a shared view of home.', empty: 'Your map will appear here', detail: 'A connected map will show taught routes, remembered objects, and patrol paths.' },
  { path: '/objects', label: 'Objects', title: 'The things you look for', description: 'A place for remembered objects and where they were last seen.', empty: 'No objects to show yet', detail: 'Objects will appear here after observations are connected. No inventory has been loaded.' },
  { path: '/patrols', label: 'Patrols', title: 'A record of the rounds', description: 'Look back at the routes your rover has travelled.', empty: 'No patrols to show yet', detail: 'Completed patrols will appear here with their path and observations.' },
  { path: '/evals', label: 'Evaluations', title: 'Evidence, clearly stated.', description: 'Understand what has been measured and how.', empty: 'No results yet', detail: 'Verified evaluation results will appear here with sample sizes and methods. No measurements have been loaded.' },
  { path: '/about', label: 'About', title: 'A helping hand around home', description: 'Recall is a home rover designed to help people find objects and notice changes.', empty: 'About this preview', detail: 'This dashboard is a navigation scaffold. Data connections and page features are still being built. Rover operation does not depend on this dashboard.' },
];

type Theme = 'system' | 'light' | 'dark';
function readTheme(): Theme {
  try { const saved = localStorage.getItem('recall-theme'); return saved === 'light' || saved === 'dark' ? saved : 'system'; }
  catch { return 'system'; }
}

function Page({ page }: { page: typeof pages[number] }) {
  return <>
    <header className="page-heading"><p className="eyebrow">{page.label === 'Home' ? 'Your home, at a glance' : page.label}</p><h1>{page.title}</h1><p className="intro">{page.description}</p></header>
    <section className="empty-state" aria-labelledby="empty-title">
      <span className="plan-mark" aria-hidden="true">⌖</span>
      <div><p className="eyebrow">{page.path === '/about' ? 'In development' : 'Not connected'}</p><h2 id="empty-title">{page.empty}</h2><p>{page.detail}</p></div>
    </section>
    {page.path === '/' && <div className="next-step"><p>Explore your dashboard</p><Link to="/changes">View changes <span aria-hidden="true">↗</span></Link><Link to="/map">Open map <span aria-hidden="true">↗</span></Link></div>}
    {page.path === '/about' && <a className="repo-link" href="https://github.com/says1117/Sought">Visit the project repository <span aria-hidden="true">↗</span></a>}
  </>;
}

function App() {
  const [theme, setTheme] = useState<Theme>(readTheme);
  const location = useLocation();
  const page = pages.find(p => p.path === location.pathname);
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try { localStorage.setItem('recall-theme', theme); } catch { /* Theme still works without storage. */ }
  }, [theme]);
  useEffect(() => {
    document.title = `${page?.label ?? 'Page not found'} · Recall`;
    document.getElementById('main-content')?.focus();
  }, [location.pathname, page]);
  return <>
    <a className="skip-link" href="#main-content">Skip to content</a>
    <div className="app-shell">
      <aside className="sidebar">
        <Link className="brand" to="/" aria-label="Recall home"><span className="brand-mark" aria-hidden="true">r.</span><span>Recall<small>Home rover</small></span></Link>
        <nav aria-label="Main navigation">{pages.map(p => <NavLink key={p.path} to={p.path} end>{p.label}<span aria-hidden="true">↗</span></NavLink>)}</nav>
        <div className="sidebar-bottom"><label htmlFor="theme">Appearance</label><select id="theme" value={theme} onChange={e => setTheme(e.target.value as Theme)}><option value="system">Use device setting</option><option value="light">Light</option><option value="dark">Dark</option></select><p>Built for a little more independence.</p></div>
      </aside>
      <div className="workspace"><div className="workspace-bar"><span>Home companion</span><span className="preview-label">Dashboard preview</span></div>
        <main id="main-content" tabIndex={-1}>{page ? <Page key={page.path} page={page}/> : <header className="page-heading"><h1>Page not found</h1><p>This address does not lead to a dashboard page.</p><Link to="/">Return home</Link></header>}</main>
        <footer>Recall <span aria-hidden="true">/</span> No live data connected</footer>
      </div>
    </div>
  </>;
}

createRoot(document.getElementById('root')!).render(<StrictMode><BrowserRouter><App /></BrowserRouter></StrictMode>);
