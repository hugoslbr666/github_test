WITH plans AS (
  SELECT
    artist_id,
    DATE(MIN(started_at)) AS min_start_date,
    DATE(MAX(ended_at))   AS max_end_date
  FROM `singulart-db-to-bigquery.singulartdb.sgt_artists_plans`
  GROUP BY 1
),

target_artists as (
select
property_email,
cast(property_singulart_artist_id as int64) as artist_id
from `singulart-data.hubspot_stitch.contacts`
where property_email in (
'mail@karinvermeer.nl','contact@veroboisvert.com','yossik2010@gmail.com','martina@martina-hamrik.de','halvorsenart@gmail.com','dimitri.likissas@gmail.com','office@kobransky.com','mc1paintings@gmail.com','sanna.johanna@orange.fr','adele777elle@gmail.com','joscoufreur@gmail.com','evgsare@gmail.com','info@an-dre-art.com','flavia@magenta-advertising.ro','shop@ronaldhunter.com','info@sialini.cz','info@artnrshinga.com','cecilia.frigati@gmail.com','aab1997@ukr.net','ruben@artistruben.com','christinebarres@yahoo.fr','cathludeau@gmail.com','kirstin.mccoy@mail.com','nadwieart@live.com','lisniakyevgen@gmail.com','shulmanart@gmail.com','kamile.lukosiute@gmail.com','art.bogatska@gmail.com','ivanaolbricht@gmail.com','joseph@jvillaart.com','andrada.art@gmail.com','tagger@mail.com','michael.lefevre7@orange.fr','info@teisalbers.com','deletesnersisyan@gmail.com','forestvika555@gmail.com','tibisoos@yahoo.com','francesca.dallabenetta@gmail.com','sarachelou@yahoo.fr','agusil@yahoo.es','vannieuwenhuijzen@planet.nl','rkhais@yahoo.com','ottowan66@gmail.com','verdeveleno69@gmail.com','vanessa.van.meerhaeghe@gmail.com','info@iravolkova.com','hpereboom@hotmail.com','nicolaeprisac@yahoo.com','info@lisaelley.com','devoc.artcontemporain@gmail.com','jovan62@hotmail.com','ngkhanhart@gmail.com','max@atelier7.com','irina.goldenfish@gmail.com','jchasseriau@gmail.com','hrantnarin.v@gmail.com','info@martinbreeze.com','studio@trayko.eu','alexanderjheaton@hotmail.com','lorenzosperzaga@gmail.com','allan.paul@gmx.de','boyer.sculpture@gmail.com','val3506@ukr.net','veronica.vilsan@gmail.com','combigian@gmail.com','info@scottallenroberts.com','philippejamin31@tutanota.com','info@nicolecijs.com','dupinpeintures@orange.fr','stabileart@gmail.com','petra.schott@gmx.net','mariclair.arts@gmail.com','josejorgenava@gmail.com','paul@paulcoghlin.com','valeria.pesciolina@gmail.com','stephane.cattaneo@yahoo.fr','punctgabriela@yahoo.ro','kbartoli70@gmail.com','rumispasov@yahoo.com','seguto@hotmail.com','edulozanno@hotmail.com','melissa@labozzettaart.com','simon@simonfindlay.com','olgaeart@gmail.com','etquesnay@gmail.com','aashwick@yahoo.co.uk','elisa.bonotti@gmail.com','victo.artist.us@gmail.com','michel.rauscher@wanadoo.fr','pepechane@hotmail.fr','jodd@freenet.de','charlotteadde@yahoo.es','tartarosart@gmail.com','nacksgalerie@gmail.com','isamignot@hotmail.com','kasiakaldowski@yahoo.co.uk','mbargholz@gmx.de','sergroy58@gmail.com','valerian.lenud@gmail.com','katiebugstars@yahoo.com','vuonglinhart@gmail.com','info@leclosier.com','shokkobo@gmail.com','e.v.a.akopian@icloud.com','hello@martin-wieland-arts.com','vava_venezia@europe.com','motuncay@outlook.com','info@joellecabanne.com','dhmpaulo@gmail.com','larissaeremeeva.art@gmail.com','sasanka908@wp.pl','amigo-k7@ukr.net','sharon.champion59@gmail.com','mkelen789@gmail.com','jonas.olga@outlook.de','a.briant38@yahoo.fr','mcafeejonathan@gmail.com','stephencimini@gmail.com','ionvacareanumarian@gmail.com','violababolart@gmail.com','luabstractart@gmail.com','bruno@aimetti.com','epinheirocosta@gmail.com','fbertona@hotmail.com','pilarlopezbaez@gmail.com','jennychwu@gmail.com','gmart67gallery@gmail.com','penya-roja@hotmail.com','laur.chicheprof@orange.fr','ruhartstudio@gmail.com','calerocalerojorge@gmail.com','a.loebbert@hotmail.com','begolafuente2016@gmail.com','deumiemuriel@hotmail.fr','contact@oliverszax.com','contact@ewengur.fr','vafa.majidli@gmail.com','io.x.ott@gmail.com','daniel.sarciat@gmail.com','chantal.parise@sfr.fr','pichonicolas@hotmail.com','krisztina@contemporaryartist.eu','drte_art@yahoo.com','klinekathleen97@gmail.com','belsky.eduard@gmail.com','contact.ncubero@gmail.com','jenniferbakerpaintings@gmail.com','judepark1022@gmail.com','art@viktoriaganhao.com','p.marlagoutsos@yahoo.gr','galeriagraphica@gmail.com','v_dikov@hotmail.com','artemgrunyka@gmail.com','verabondareart@gmail.com','lynette@lynettereed.com','sandrine.hirson@orange.fr','info@agozdecka.pl','deletephil@artphilsmith.com','anton_679@bk.ru','vcozmolici@yahoo.com','max.guarini@yahoo.it','zue1980@icloud.com')
)

SELECT
  aa.artist_id,
  aa.email,
  plans.max_end_date                                                    AS churn_date,
  IF(DATE(sa.paid_at) <= plans.max_end_date, 'before_churn', 'after_churn') AS churn_period,
  COUNT(DISTINCT sa.sale_id)                                            AS nb_sales,
  SUM(sa.purchaseEurAmountWithShipping)                                 AS BV_first_click
FROM `singulart-data.connected_sheets.sales_attribution` sa
INNER JOIN `singulart-data.connected_sheets.all_artists` aa
  ON SAFE_CAST(aa.artist_id AS STRING) = sa.email_1st_click_landing_object_id
INNER JOIN plans
  ON plans.artist_id = aa.artist_id
INNER JOIN target_artists ta
  ON ta.artist_id = aa.artist_id
WHERE sa.email_1st_click_campaign_name = "TEMPLATE ARTIST"
  AND sa.email_1st_click_landing_tpl = "artist"
  AND sa.paid_at >= "2023-09-01"
  AND plans.max_end_date IS NOT NULL
GROUP BY
  aa.artist_id,
  aa.email,
  plans.max_end_date,
  churn_period
ORDER BY
  aa.artist_id,
  churn_period