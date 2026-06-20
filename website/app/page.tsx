import Image from "next/image";

const focusAreas = [
  {
    title: "XiaoHuaEr on the desktop",
    body: "A small companion presence for quick chat, mood, reminders, focus, local voice, and gentle return points during the day.",
  },
  {
    title: "Journal, reminders, and focus",
    body: "Keep the everyday loop close: capture notes, create reminders, start Pomodoro focus, and save the result back into a local journal.",
  },
  {
    title: "Local MCP workflows",
    body: "Expose companion-owned reminders, journal, focus, asset upload, and review actions through a bundled stdio helper.",
  },
];

const mcpTools = [
  "companion.reminder.parseDraft",
  "companion.reminder.create",
  "companion.reminder.createBatch",
  "companion.journal.appendToday",
  "companion.pomodoro.startFocus",
  "companion.asset.upload",
  "companion.focusReview.generate",
];

export default function Home() {
  return (
    <main className="min-h-screen bg-[#f7f8f5] text-[#18201e]">
      <header className="border-b border-[#d8ded7] bg-[#f7f8f5]/95 backdrop-blur">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-5 py-4 sm:px-8">
          <a className="flex items-center gap-3" href="#top" aria-label="Companion home">
            <Image
              src="/companion-icon-1024.png"
              alt=""
              className="size-9 rounded-lg shadow-sm"
              width={1024}
              height={1024}
              unoptimized
            />
            <span className="text-base font-semibold">Companion</span>
          </a>
          <nav className="hidden items-center gap-6 text-sm text-[#5c6662] md:flex">
            <a className="hover:text-[#0f6f5d]" href="#focus">
              Focus
            </a>
            <a className="hover:text-[#0f6f5d]" href="#mcp">
              MCP
            </a>
            <a className="hover:text-[#0f6f5d]" href="#build">
              Build
            </a>
          </nav>
        </div>
      </header>

      <section id="top" className="border-b border-[#d8ded7]">
        <div className="mx-auto grid max-w-6xl gap-10 px-5 py-10 sm:px-8 lg:grid-cols-[0.82fr_1.18fr] lg:items-center">
          <div>
            <h1 className="text-5xl font-semibold tracking-normal text-[#121816] sm:text-6xl">
              Companion
            </h1>
            <p className="mt-5 max-w-xl text-xl font-medium leading-snug text-[#26312f]">
              A local macOS companion app centered on XiaoHuaEr, journal, reminders,
              focus, and personal MCP workflows.
            </p>
            <p className="mt-4 max-w-xl text-base leading-7 text-[#5c6662]">
              Companion is the home for desktop-pet-centered everyday workflows:
              notes, reminders, focus, AI actions, and local automation.
            </p>
            <div className="mt-8 grid gap-3 text-sm sm:grid-cols-3">
              <div className="border-l-2 border-[#0f6f5d] pl-3">
                <span className="block font-semibold">Data root</span>
                <span className="text-[#5c6662]">~/.companion</span>
              </div>
              <div className="border-l-2 border-[#f2b84b] pl-3">
                <span className="block font-semibold">Bundle</span>
                <span className="text-[#5c6662]">Companion.app</span>
              </div>
              <div className="border-l-2 border-[#4576ff] pl-3">
                <span className="block font-semibold">MCP</span>
                <span className="text-[#5c6662]">CompanionMCP</span>
              </div>
            </div>
          </div>

          <div className="space-y-3">
            <div className="flex items-center justify-between rounded-lg border border-[#d8ded7] bg-white px-4 py-3 shadow-sm">
              <div className="flex items-center gap-3">
                <Image
                  src="/companion-icon-1024.png"
                  alt="Companion app icon"
                  className="size-12 rounded-lg"
                  width={1024}
                  height={1024}
                  priority
                  unoptimized
                />
                <div>
                  <p className="text-sm font-semibold">XiaoHuaEr workspace</p>
                  <p className="text-xs text-[#6b7772]">Reminders, journal, focus, and local presence.</p>
                </div>
              </div>
              <span className="rounded-md bg-[#e4f4ee] px-3 py-1 text-xs font-medium text-[#0f6f5d]">
                Seed 0.2.0
              </span>
            </div>
            <Image
              src="/companion-readme-hero.png"
              alt="Companion brand artwork with XiaoHuaEr and the Always by your side tagline."
              className="w-full rounded-lg border border-[#d8ded7] bg-white shadow-2xl shadow-[#1f2b26]/10"
              width={1448}
              height={1086}
              priority
              unoptimized
            />
          </div>
        </div>
      </section>

      <section id="focus" className="mx-auto max-w-6xl px-5 py-14 sm:px-8">
        <div className="grid gap-4 md:grid-cols-3">
          {focusAreas.map((item) => (
            <article className="rounded-lg border border-[#d8ded7] bg-white p-5 shadow-sm" key={item.title}>
              <h2 className="text-lg font-semibold">{item.title}</h2>
              <p className="mt-3 text-sm leading-7 text-[#5c6662]">{item.body}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="border-y border-[#d8ded7] bg-[#eef3ef]">
        <div className="mx-auto grid max-w-6xl gap-8 px-5 py-14 sm:px-8 lg:grid-cols-2 lg:items-center">
          <Image
            src="/xiaohuaer-quick-menu.png"
            alt="XiaoHuaEr quick menu preview."
            className="mx-auto w-full max-w-md rounded-lg border border-[#d8ded7] bg-white shadow-lg"
            width={560}
            height={560}
            unoptimized
          />
          <div>
            <h2 className="text-3xl font-semibold tracking-normal">A companion-first boundary.</h2>
            <p className="mt-4 text-base leading-7 text-[#5c6662]">
              The current app boundary is companion-first: lightweight AI settings, local data,
              focused MCP workflow tools, and no inherited developer-console configuration layer.
            </p>
          </div>
        </div>
      </section>

      <section id="mcp" className="mx-auto max-w-6xl px-5 py-14 sm:px-8">
        <div className="grid gap-8 lg:grid-cols-[0.8fr_1.2fr]">
          <div>
            <h2 className="text-3xl font-semibold tracking-normal">Local tools, new namespace.</h2>
            <p className="mt-4 text-base leading-7 text-[#5c6662]">
              Companion exposes local workflow primitives through `CompanionMCP`, using `companion.*`
              tool IDs so companion workflows stay separate and easy to audit.
            </p>
          </div>
          <div className="grid gap-2 sm:grid-cols-2">
            {mcpTools.map((tool) => (
              <code className="rounded-md border border-[#d8ded7] bg-white px-3 py-2 text-sm text-[#26312f]" key={tool}>
                {tool}
              </code>
            ))}
          </div>
        </div>
      </section>

      <section id="build" className="border-t border-[#d8ded7] bg-white">
        <div className="mx-auto max-w-6xl px-5 py-10 sm:px-8">
          <h2 className="text-2xl font-semibold tracking-normal">Build locally</h2>
          <div className="mt-5 grid gap-3 md:grid-cols-2">
            <pre className="overflow-x-auto rounded-lg bg-[#121816] p-4 text-sm text-white">
              <code>swift build --product Companion</code>
            </pre>
            <pre className="overflow-x-auto rounded-lg bg-[#121816] p-4 text-sm text-white">
              <code>CODE_SIGN_IDENTITY=- bash scripts/build-menu-bar-app.sh</code>
            </pre>
          </div>
        </div>
      </section>
    </main>
  );
}
