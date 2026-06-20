import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Companion | macOS desktop companion",
  description:
    "Companion is a local macOS desktop companion centered on XiaoHuaEr, journal, reminders, focus, and MCP workflows.",
  icons: {
    icon: "/companion-icon-1024.png",
    shortcut: "/companion-icon-1024.png",
    apple: "/companion-icon-1024.png",
  },
  openGraph: {
    title: "Companion",
    description: "A local macOS desktop companion for XiaoHuaEr workflows.",
    images: ["/companion-readme-hero.png"],
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-CN">
      <body>{children}</body>
    </html>
  );
}
