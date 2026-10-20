// Variables used by Scriptable.
// These must be at the very top of the file. Do not edit.
// icon-color: yellow; icon-glyph: subway;

// Next Manhattan-bound R train at Prospect Av, Brooklyn.
// A home-screen and lock-screen widget for Scriptable (https://scriptable.app).
// Reads the MTA's real-time feed for the N/Q/R/W lines; no API key needed.
// For another stop or line, change the settings below: the feed, the color and
// the terminals go with the line.

// ---- Settings ---------------------------------------------------------------
const STOP_ID = "R34N"; // Prospect Av, Manhattan-bound ("R34S" is toward Bay Ridge)
// The lines, as the feed names them: "GS", "FS" and "H" are the shuttles, and a
// line's express runs ("6X") are shown with it
const ROUTES = ["R"]; // add "N" to also show N trains when they run local
const STATION = "Prospect Av";
const HEADING = "to Manhattan";
// The feed for ROUTES' group of lines: it ends -ace, -bdfm, -g, -jz, -l, -nqrw or
// -si, or at "gtfs" for the 1 to 7 and the 42 St shuttle
const FEED_URL = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2Fgtfs-nqrw";
// The line's color, for its bullet (the label on it is black if it's light)
const LINE_COLOR = "#FCCC0A";
// The MTA makes its feed anew about every 30 seconds; one older than this has stopped updating
const STALE_SECONDS = 3 * 60;
// Where a train ends up, keyed by the last stop of its trip
const TERMINALS = {
  R01N: "Astoria", G08N: "Forest Hills", G21N: "Queens Plaza", R27N: "Whitehall St",
  R45S: "Bay Ridge", D43S: "Coney Island",
};
// -----------------------------------------------------------------------------

const BULLET = new Color(LINE_COLOR);
// Black on the light bullets, as on the N, Q, R and W, and white on the rest
const BULLET_LABEL = 0.299 * BULLET.red + 0.587 * BULLET.green + 0.114 * BULLET.blue > 0.57 ? Color.black() : Color.white();
const GREEN = new Color("#4CD964");
const BACKGROUND = new Color("#111111");
const DIM = new Color("#9A9A9A");
const DOT = "\u00b7"; // written as an escape so the script stays plain ASCII
// The express runs of the 5, 6, 7 and F are their own routes in the feeds ("6X")
const line = (route) => route.replace(/^([567F])X$/, "$1");
// What a line's bullet says: an S for the shuttles
const label = (route) => (["GS", "FS", "H"].includes(route) ? "S" : route);

const family = config.widgetFamily || "medium"; // run in the app: preview the medium size
let widget;
try {
  widget = trainWidget(await upcomingTrains());
} catch (error) {
  widget = messageWidget("Couldn't reach the MTA", String(error.message || error));
  widget.refreshAfterDate = new Date(Date.now() + 2 * 60 * 1000);
}
if (config.runsInWidget) Script.setWidget(widget);
else if (family === "small") await widget.presentSmall();
else await widget.presentMedium();
Script.complete();

async function upcomingTrains() {
  const request = new Request(FEED_URL);
  request.timeoutInterval = 20;
  const data = await request.load();
  const status = request.response && request.response.statusCode;
  if (status !== 200) throw new Error(`MTA feed answered HTTP ${status}`);
  const now = new Date();
  return arrivalsAt(STOP_ID, data.getBytes()).filter((train) => ROUTES.includes(train.route) && train.time > now);
}

// Decodes just enough of the GTFS-realtime protobuf (gtfs.org/realtime) to list,
// for every trip that stops at stopId and goes on from it, its line, arrival
// time, last stop and whether a train is assigned to it (live=true: a live
// prediction; false: the MTA hasn't assigned a train yet, so the time is still
// the timetable's). Throws if the feed says it was made over STALE_SECONDS ago.
function arrivalsAt(stopId, bytes) {
  let pos = 0;
  const varint = () => {
    let value = 0;
    let scale = 1;
    let byte;
    do {
      byte = bytes[pos++];
      value += (byte & 0x7f) * scale;
      scale *= 128;
    } while (byte & 0x80);
    return value;
  };
  const skip = (wireType) => {
    if (wireType === 0) varint();
    else if (wireType === 1) pos += 8;
    else if (wireType === 2) {
      const length = varint();
      pos += length;
    } else if (wireType === 5) pos += 4;
    else throw new Error(`Unexpected protobuf wire type ${wireType}`);
  };
  const string = () => {
    const length = varint();
    let text = "";
    for (let i = pos; i < pos + length; i++) text += String.fromCharCode(bytes[i]); // IDs are ASCII
    pos += length;
    return text;
  };
  // Reads fields up to `end`, handing each to handlers[fieldNumber]; others are skipped.
  const fields = (end, handlers) => {
    while (pos < end) {
      const key = varint();
      const handler = handlers[Math.floor(key / 8)];
      if (handler) handler();
      else skip(key % 8);
    }
    if (pos !== end) throw new Error("Malformed MTA feed");
  };
  const message = (handlers) => {
    const length = varint();
    fields(pos + length, handlers);
  };
  const eventTime = () => {
    let time = 0;
    message({ 2: () => (time = varint()) }); // StopTimeEvent.time
    return time;
  };

  const arrivals = [];
  let made = 0;
  fields(bytes.length, {
    1: () => message({ 3: () => (made = varint()) }), // FeedMessage.header: its timestamp
    2: () => message({ // FeedMessage.entity
      3: () => { // FeedEntity.trip_update
        let route = "";
        let time = 0;
        let lastStop = "";
        let live = false;
        message({
          1: () => message({ // TripUpdate.trip
            5: () => (route = string()), // route_id
            1001: () => message({ 2: () => (live = varint() === 1) }), // the MTA's extension: is_assigned
          }),
          2: () => { // TripUpdate.stop_time_update
            let stop = "";
            let arrival = 0;
            let departure = 0;
            message({
              4: () => (stop = string()),
              2: () => (arrival = eventTime()),
              3: () => (departure = eventTime()),
            });
            if (stop === stopId) time = arrival || departure;
            lastStop = stop;
          },
        });
        // A trip that ends at stopId doesn't leave from it
        if (time && lastStop !== stopId) {
          arrivals.push({ route: line(route), time: new Date(time * 1000), terminal: TERMINALS[lastStop], live });
        }
      },
    }),
  });
  if (made && Date.now() / 1000 - made > STALE_SECONDS) {
    throw new Error(`The MTA's feed hasn't updated since ${clock(new Date(made * 1000), true)}`);
  }
  return arrivals.sort((a, b) => a.time - b.time);
}

// ---- Layout -----------------------------------------------------------------

function trainWidget(trains) {
  if (trains.length === 0) {
    const widget = messageWidget(`No ${ROUTES.map(label).join("/")} trains predicted`, "Check mta.info for service changes");
    widget.refreshAfterDate = new Date(Date.now() + 5 * 60 * 1000);
    return widget;
  }
  const [next, ...later] = trains;
  const widget = new ListWidget();
  // The earliest iOS may refresh: as soon as it likes, or once this train has left.
  // iOS rations refreshes, so this only lets it refresh sooner, never forces it.
  widget.refreshAfterDate = new Date(Math.min(next.time.getTime() + 10 * 1000, Date.now() + 60 * 1000));

  if (family === "accessoryInline") {
    widget.addText(`${label(next.route)} ${[next, ...later.slice(0, 2)].map((t) => clock(t.time)).join(` ${DOT} `)}`);
    return widget;
  }
  if (family === "accessoryRectangular" || family === "accessoryCircular") {
    const title = widget.addText(family === "accessoryCircular" ? label(next.route) : `${label(next.route)} ${DOT} ${STATION}`);
    title.font = Font.boldSystemFont(family === "accessoryCircular" ? 16 : 13);
    if (family === "accessoryCircular") title.centerAlignText();
    const timer = countdown(widget, next, 22);
    if (family === "accessoryCircular") timer.centerAlignText();
    if (family === "accessoryRectangular" && later.length > 0) {
      const then = widget.addText(`then ${later.slice(0, 2).map((t) => clock(t.time)).join(", ")}`);
      then.font = Font.systemFont(12);
    }
    return widget;
  }

  widget.backgroundColor = BACKGROUND;
  widget.setPadding(14, 14, 14, 14);
  if (family === "small") {
    nextTrain(widget, next, later);
    return widget;
  }

  const row = widget.addStack();
  const left = row.addStack();
  left.layoutVertically();
  left.size = new Size(150, 0); // a live timer takes all the width it's offered
  nextTrain(left, next, []); // the later trains get their own column
  if (later.length === 0) return widget;
  row.addSpacer(16);
  const right = row.addStack();
  right.layoutVertically();
  right.addSpacer(4);
  const heading = right.addText("NEXT");
  heading.font = Font.semiboldSystemFont(11);
  heading.textColor = DIM;
  right.addSpacer(6);
  for (const train of later.slice(0, family === "large" ? 10 : 4)) {
    const line = right.addStack();
    line.centerAlignContent();
    if (ROUTES.length > 1) {
      bullet(line, train.route, 16);
      line.addSpacer(6);
    }
    const time = line.addText(clock(train.time));
    time.font = Font.semiboldSystemFont(15);
    time.textColor = statusColor(train);
    if (train.terminal && train.terminal !== next.terminal) {
      line.addSpacer(8);
      const destination = line.addText(train.terminal);
      destination.font = Font.systemFont(13);
      destination.textColor = DIM;
      destination.lineLimit = 1;
    }
    right.addSpacer(5);
  }
  right.addSpacer();
  return widget;
}

// Header, a live countdown to the next train, and the times of the two after it
function nextTrain(stack, next, later) {
  const header = stack.addStack();
  header.centerAlignContent();
  bullet(header, next.route, 26);
  header.addSpacer(7);
  const names = header.addStack();
  names.layoutVertically();
  const station = names.addText(STATION);
  station.font = Font.boldSystemFont(14);
  station.textColor = Color.white();
  station.lineLimit = 1;
  station.minimumScaleFactor = 0.8;
  const heading = names.addText(HEADING);
  heading.font = Font.systemFont(11);
  heading.textColor = DIM;

  stack.addSpacer();
  const timer = countdown(stack, next, 34);
  timer.textColor = statusColor(next);
  const arrives = stack.addStack();
  const arrival = arrives.addText(clock(next.time, true));
  arrival.font = Font.mediumSystemFont(12);
  arrival.textColor = statusColor(next);
  arrival.lineLimit = 1;
  if (next.terminal) {
    const destination = arrives.addText(` ${DOT} ${next.terminal}`);
    destination.font = Font.mediumSystemFont(12);
    destination.textColor = DIM;
    destination.lineLimit = 1;
    destination.minimumScaleFactor = 0.7;
  }
  if (later.length > 0) {
    stack.addSpacer(3);
    const then = stack.addStack();
    const label = then.addText("Then ");
    label.font = Font.systemFont(12);
    label.textColor = DIM;
    later.slice(0, 2).forEach((train, index) => {
      if (index > 0) {
        const comma = then.addText(", ");
        comma.font = Font.systemFont(12);
        comma.textColor = DIM;
      }
      const time = then.addText(clock(train.time));
      time.font = Font.systemFont(12);
      time.textColor = statusColor(train);
    });
  }
}

// Green for a live prediction, white for a timetable time the MTA hasn't
// assigned a train to yet
function statusColor(train) {
  return train.live ? GREEN : Color.white();
}

// Counts down live on the widget, down to the train's arrival (it then counts
// back up until iOS next refreshes the widget)
function countdown(stack, train, size) {
  const timer = stack.addDate(train.time);
  timer.applyTimerStyle();
  timer.leftAlignText();
  timer.font = Font.boldSystemFont(size);
  timer.minimumScaleFactor = 0.6;
  timer.lineLimit = 1;
  return timer;
}

function bullet(stack, route, size) {
  const circle = stack.addStack();
  circle.size = new Size(size, size);
  circle.cornerRadius = size / 2;
  circle.backgroundColor = BULLET;
  circle.centerAlignContent();
  const text = label(route);
  const letter = circle.addText(text);
  // Two letters, as on the SI, are smaller
  letter.font = Font.boldSystemFont(Math.round(size * (text.length > 1 ? 0.45 : 0.62)));
  letter.textColor = BULLET_LABEL;
}

function messageWidget(title, detail) {
  const widget = new ListWidget();
  if (family.startsWith("accessory")) {
    widget.addText(title).font = Font.semiboldSystemFont(12);
    return widget;
  }
  widget.backgroundColor = BACKGROUND;
  widget.setPadding(14, 14, 14, 14);
  const header = widget.addStack();
  header.centerAlignContent();
  bullet(header, ROUTES[0], 26);
  header.addSpacer(7);
  const station = header.addText(STATION);
  station.font = Font.boldSystemFont(14);
  station.textColor = Color.white();
  widget.addSpacer();
  const titleText = widget.addText(title);
  titleText.font = Font.semiboldSystemFont(15);
  titleText.textColor = Color.white();
  const detailText = widget.addText(detail);
  detailText.font = Font.systemFont(11);
  detailText.textColor = DIM;
  detailText.lineLimit = 3;
  return widget;
}

function clock(date, withPeriod = false) {
  const formatter = new DateFormatter();
  formatter.dateFormat = withPeriod ? "h:mm a" : "h:mm";
  return formatter.string(date);
}
