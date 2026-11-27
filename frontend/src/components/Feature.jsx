import { ArrowRight } from 'lucide-react';

function Feature({icon,title,text}){return <article className="feature-card"><span className="feature-icon">{icon}</span><h3>{title}</h3><p>{text}</p><ArrowRight className="feature-arrow" size={18}/></article>}
export default Feature;
