/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the license, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this software.  If not, see <http://www.gnu.org/licenses/>.
 */

module ag.backend.debian.debpkg;

import std.stdio;
import std.string;
import std.process : pipeProcess, Redirect, wait;
import std.file;
import std.array : empty;
import ag.config;
import ag.archive;
import ag.backend.intf;
import ag.logging;


class DebPackage : Package
{
private:
    string pkgname;
    string pkgver;
    string pkgarch;
    string pkgmaintainer;
    string[string] desc;

    bool contentsRead;
    string[] contentsL;

    string tmpDir;
    string dataArchive;
    string controlArchive;

    string debFname;

public:
    @property string name () { return pkgname; }
    @property string ver () { return pkgver; }
    @property string arch () { return pkgarch; }
    @property string[string] description () { return desc; }
    @property string filename () { return debFname; }
    @property void filename (string fname) { debFname = fname; }
    @property string maintainer () { return pkgmaintainer; }
    @property void maintainer (string maint) { pkgmaintainer = maint; }

    this (string pname, string pver, string parch)
    {
        import std.path;

        pkgname = pname;
        pkgver = pver;
        pkgarch = parch;

        contentsRead = false;

        auto conf = Config.get ();
        tmpDir = buildPath (conf.getTmpDir (), format ("%s-%s_%s", name, ver, arch));
    }

    ~this ()
    {
        // FIXME: Makes the GC crash - find out why (the error should be ignored...)
        // if (tmpDir !is null)
        // close ();
    }

    bool isValid ()
    {
        if ((!name) || (!ver) || (!arch))
            return false;
        return true;
    }

    override
    string toString ()
    {
        return format ("%s/%s/%s", name, ver, arch);
    }

    void setDescription (string text, string locale)
    {
        desc[locale] = text;
    }

    private auto openPayloadArchive ()
    {
        auto pa = new ArchiveDecompressor ();
        if (!dataArchive) {
            import std.regex;
            import std.path;

            // extract the payload to a temporary location first
            pa.open (this.filename);
            mkdirRecurse (tmpDir);

            string[] files;
            try {
                files = pa.extractFilesByRegex (ctRegex!(r"data\.*"), tmpDir);
            } catch (Exception e) { throw e; }

            if (files.length == 0)
                return null;
            dataArchive = files[0];
        }

        pa.open (dataArchive);
        return pa;
    }

    private auto openControlArchive ()
    {
        auto ca = new ArchiveDecompressor ();
        if (!controlArchive) {
            import std.regex;
            import std.path;

            // extract the payload to a temporary location first
            ca.open (this.filename);
            mkdirRecurse (tmpDir);

            string[] files;
            try {
                files = ca.extractFilesByRegex (ctRegex!(r"control\.*"), tmpDir);
            } catch (Exception e) { throw e; }

            if (files.empty)
                return null;
            controlArchive = files[0];
        }

        ca.open (controlArchive);
        return ca;
    }

    const(ubyte)[] getFileData (string fname)
    {
        auto pa = openPayloadArchive ();
        return pa.readData (fname);
    }

    @property
    string[] contents ()
    {
        if (contentsRead)
            return contentsL;

        if (pkgname.endsWith ("icon-theme")) {
            // the md5sums file does not contain symbolic links - while that is okay-ish for regular
            // packages, it is not acceptable for icon themes, since those rely on symlinks to provide
            // aliases for certain icons. So, use the slow method for reading contents information here.

            auto pa = openPayloadArchive ();
            contentsL = pa.readContents ();
            contentsRead = true;

            return contentsL;
        }

        // use the md5sums file of the .deb control archive to determine
        // the contents of this package.
        // this is way faster than going through the payload directly, and
        // has the same accuracy.
        auto ca = openControlArchive ();
        const(ubyte)[] md5sumsData;
        try {
            md5sumsData = ca.readData ("./md5sums");
        } catch (Exception e) {
            logWarning ("Could not read md5sums file for package %s: %s", Package.getId (this), e.msg);
            return [];
        }

        auto md5sums = cast(string) md5sumsData;
        try {
            md5sums = std.utf.toUTF8 (md5sums);
        } catch (Exception e) {
            logError ("Could not decode md5sums file for package %s: %s", Package.getId (this), e.msg);
            return [];
        }

        // TODO: Preallocate space for the contents list using
        // the splitLines count?

        foreach (line; md5sums.splitLines ()) {
            auto parts = line.split ("  ");
            if (parts.length <= 0)
                continue;
            string c = join (parts[1..$], "  ");
            contentsL ~= "/" ~ c;
        }

        contentsRead = true;
        return contentsL;
    }

    void close ()
    {
        try {
            if (exists (tmpDir))
                rmdirRecurse (tmpDir);
            dataArchive = null;
            controlArchive = null;
        } catch {}
    }
}