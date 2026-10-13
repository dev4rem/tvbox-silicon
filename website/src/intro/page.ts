// The standalone film page (/intro/): the film, a back link, and ?t= / ?lang= support.
import "@fontsource/inter/400.css";
import "@fontsource/inter/500.css";
import "@fontsource/inter/600.css";
import "@fontsource/inter/700.css";
import "./page.css";
import { detectLang } from "../i18n/detect";
import { mountFilm } from "./film";
import { tr } from "./film-i18n";
import { sfSvg } from "../sf-icons";

const lang = detectLang();
const brand = lang === "ja" || lang === "zh-Hant" ? "映匣" : "Yingxia";
document.documentElement.lang = lang;
const host = document.getElementById("film-host")!;
document.title = tr(lang, "How Yingxia works").replace("Yingxia", brand);
document.querySelector("#back")!.innerHTML = `${sfSvg("chevron.left")}${brand}`;
document.querySelector("#how")!.textContent = tr(lang, "How it works");

const at = new URLSearchParams(location.search).get("t");
mountFilm(host, {
  lang,
  keys: true,
  startAt: at === null ? undefined : Number(at) || 0,
});
