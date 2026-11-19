import assert from "node:assert/strict";
import test from "node:test";
import {
  TYPE_OPTIONS,
  applicationAddError,
  applicationEmailHtml,
  applicationReviewLines,
  applicationUploadError,
} from "./coachApplicationFiles.mjs";

test("the dropdown order is fixed", () => {
  assert.deepEqual(TYPE_OPTIONS.map((option) => option[1]), [
    "Certification",
    "CPR",
    "Degree",
    "Location approval notice / Owner permission",
    "Insurance",
    "Before and after photo",
    "Location photo (max 8)",
  ]);
});

test("a credential, the approval file, and insurance are enough", () => {
  assert.equal(applicationUploadError(["cpr", "location-approval", "insurance"]), null);
  assert.equal(applicationUploadError(["degree", "location-approval", "insurance"]), null);
});

test("before-and-after photos and location photos are not required", () => {
  assert.equal(applicationUploadError(["certification", "location-approval", "insurance"]), null);
});

test("each required group blocks the application on its own", () => {
  assert.match(applicationUploadError(["location-approval", "insurance"]), /certification, CPR card, or degree/);
  assert.match(applicationUploadError(["certification", "insurance"]), /location approval notice or owner permission/);
  assert.match(applicationUploadError(["certification", "location-approval"]), /insurance/);
});

test("a before-and-after pair counts as two files, and the cap is 20", () => {
  assert.equal(applicationAddError({ kind: "before-after", filesSoFar: 18, locationPhotos: 0 }), null);
  assert.match(applicationAddError({ kind: "before-after", filesSoFar: 19, locationPhotos: 0 }), /20 files/);
  assert.match(applicationAddError({ kind: "location-photo", filesSoFar: 8, locationPhotos: 8 }), /8 location photos/);
});

test("the owner email names every type and places a pair side by side", () => {
  const lines = applicationReviewLines({
    documents: [
      { kind: "cpr", name: "cpr-card.pdf" },
      { kind: "location-approval", name: "notice.pdf" },
      { kind: "insurance", name: "policy.pdf" },
    ],
    beforeAfterPairs: 1,
    locationPhotoCount: 2,
  });
  assert.equal(lines[1], "CPR: cpr-card.pdf");
  assert.equal(lines[3], "Location approval notice / Owner permission: notice.pdf");
  assert.equal(lines[5], "Before and after photo: 1 pair, side by side");
  const html = applicationEmailHtml(lines.join("\n"), [{
    beforeUrl: "https://files.example/before.jpg",
    afterUrl: "https://files.example/after.jpg",
  }]);
  const beforeAt = html.indexOf("https://files.example/before.jpg");
  const afterAt = html.indexOf("https://files.example/after.jpg");
  assert.ok(beforeAt > 0 && afterAt > beforeAt);
  assert.match(html, /Before<\/div>/);
  assert.match(html, /After<\/div>/);
});
