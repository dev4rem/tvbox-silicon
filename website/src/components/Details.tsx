import type { ComponentType } from "react";
import { useI18n } from "../i18n/I18nProvider";
import type { TextKey } from "../i18n/strings";
import { Headline } from "./Headline";
import { CastIcon, CodeIcon, DevicesIcon, GlobeIcon, LockIcon, PlayIcon, QrIcon, QualityIcon, SubscriptionIcon } from "./icons";
import { Reveal } from "./Reveal";

const TILES: { Icon: ComponentType; title: TextKey; body: TextKey }[] = [
  { Icon: SubscriptionIcon, title: "g.sub.t", body: "g.sub.b" },
  { Icon: CodeIcon, title: "g.runtime.t", body: "g.runtime.b" },
  { Icon: PlayIcon, title: "g.play.t", body: "g.play.b" },
  { Icon: QualityIcon, title: "g.hd.t", body: "g.hd.b" },
  { Icon: CastIcon, title: "g.cast.t", body: "g.cast.b" },
  { Icon: QrIcon, title: "g.qr.t", body: "g.qr.b" },
  { Icon: LockIcon, title: "g.private.t", body: "g.private.b" },
  { Icon: GlobeIcon, title: "g.lang.t", body: "g.lang.b" },
  { Icon: DevicesIcon, title: "g.devices.t", body: "g.devices.b" },
];

export function Details() {
  const { t } = useI18n();
  return (
    <section className="section">
      <Reveal>
        <Headline lines={["more.l1", "more.l2"]} small />
      </Reveal>
      <div className="grid">
        {TILES.map(({ Icon, title, body }) => (
          <Reveal className="tile" key={title}>
            <Icon />
            <h3>{t(title)}</h3>
            <p>{t(body)}</p>
          </Reveal>
        ))}
      </div>
    </section>
  );
}
