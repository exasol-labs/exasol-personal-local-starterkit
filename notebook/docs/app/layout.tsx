import { Inter } from 'next/font/google';
import { Provider } from '@/components/provider';
import './global.css';

const inter = Inter({
  subsets: ['latin'],
});

export default function Layout({ children }: LayoutProps<'/'>) {
  return (
    <html lang="en" className={inter.className} suppressHydrationWarning>
      <head>
        {/* Before hydration: a host that embeds the docs (the frame nb.docs()
            puts under a notebook cell) can pass its theme as ?theme=dark|light,
            and the sidebar opens at the width the reader last dragged it to. */}
        <script
          dangerouslySetInnerHTML={{
            __html:
              'try{var t=new URLSearchParams(location.search).get("theme");if(t==="dark"||t==="light"){localStorage.setItem("theme",t)}var w=parseInt(localStorage.getItem("exakit-docs-sidebar-width"),10);if(w>=200&&w<=520){document.documentElement.style.setProperty("--exakit-sidebar-width",w+"px")}}catch(e){}',
          }}
        />
      </head>
      <body className="flex flex-col min-h-screen">
        <Provider>{children}</Provider>
      </body>
    </html>
  );
}
