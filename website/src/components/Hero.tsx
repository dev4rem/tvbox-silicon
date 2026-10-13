import { useI18n } from "../i18n/I18nProvider";
import { DownloadButton } from "./controls";
import { Headline } from "./Headline";
import { HeroFilm } from "./HeroFilm";
import { Reveal } from "./Reveal";
import { SFSymbol } from "./SFSymbol";

export function Hero() {
  const { t, lang } = useI18n();
  return (
    <section className="hero">
      <Headline as="h1" lines={["hero.l1", "hero.l2"]} animate />
      <p className="lead">{t("hero.sub")}</p>
      <div className="actions">
        <DownloadButton />
        <a className="link" href="#features">
          {t("hero.more")} <SFSymbol name="chevron.down" />
        </a>
      </div>
      <p className="meta">{t("dl.req")}</p>
      <Reveal className="hero-stage hero-film">
        <HeroFilm />
        <a className="link hero-film-link" href={`/intro/?lang=${lang}`}>
          {t("hero.film")} <SFSymbol name="chevron.right" />
        </a>
      </Reveal>
    </section>
  );
}
