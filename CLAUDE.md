# Release-Prozess

Wenn der Nutzer sagt, dass er bereit für einen Release ist (z. B. "ready für einen Release",
"Release vorbereiten", "Version X.Y.Z veröffentlichen"), führe diese Schritte aus:

1. **Version festlegen**: Wenn keine explizite Versionsnummer genannt wurde, schlage anhand der
   Commits seit dem letzten Git-Tag eine sinnvolle nächste Version vor (Patch für Bugfixes, Minor
   für neue Features) und frag kurz nach, bevor du weitermachst.

2. **`.toc`-Dateien aktualisieren**: Setze `## Version:` in **beiden** Dateien,
   `SmuRankUp_Camelot.toc` **und** `SmuRankUp_TBC.toc`, auf dieselbe neue Version. Beide Dateien
   müssen immer exakt dieselbe Versionsnummer tragen.

3. **`CHANGELOG.md` pflegen**: Füge direkt unter der Überschrift einen neuen Abschnitt ein:

   ```
   ## <version> - <YYYY-MM-DD>
   - <Änderung 1>
   - <Änderung 2>
   ```

   Leite die Einträge aus `git log <letzter-tag>..HEAD --oneline` ab, formuliere sie aber als
   lesbare, nutzerorientierte Sätze - keine rohen Commit-Messages, keine internen
   Refactoring-Details, die für CurseForge-Nutzer irrelevant sind.

4. **Committen**: Commit-Message `Release <version>`, enthält die beiden `.toc`- und die
   `CHANGELOG.md`-Änderung.

5. **Taggen**: Annotierten Git-Tag exakt mit der Versionsnummer erstellen, **ohne "v"-Prefix**
   (z. B. `1.0.7`) - dieser Tag wird von der CurseForge-Pipeline (BigWigsMods/packager) 1:1 als
   `project-version` übernommen. Beide `.toc`-Varianten (Camelot + TBC) landen in einem
   gemeinsamen Zip.

6. **Push bestätigen lassen**: Frag nach, bevor du Commit und Tag nach GitHub pushst
   (`git push && git push --tags`). Das löst automatisch den CurseForge-Upload über die GitHub
   Action aus (Trigger: nur Tags, keine normalen Pushes auf `main`).

Die `.pkgmeta` nutzt `manual-changelog`, d. h. der Packager lädt exakt den Inhalt von
`CHANGELOG.md` zu CurseForge hoch statt automatisch aus dem Git-Log zu generieren - Schritt 3 ist
daher für einen sauberen Changelog auf CurseForge wichtig.
