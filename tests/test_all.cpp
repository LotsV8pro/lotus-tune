#include <QtTest/QtTest>
#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QStandardPaths>

#include "downloads.h"
#include "player.h"
#include "appconfig.h"

class TestLotusTune : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void testSafeSegment();
    void testFriendlyError();
    void testPartialFilesCleanup();
    void testCountAudioFiles();
    void testUniqueListFolder();
    void testNormalizeUrl();
    void testAppConfig();
};

void TestLotusTune::initTestCase()
{
    qDebug() << "Iniciando suite de pruebas de Lotus Tune 1.0...";
}

void TestLotusTune::testSafeSegment()
{
    // Segmentos básicos
    QCOMPARE(Downloads::safeSegment("Coldplay - Yellow"), QString("Coldplay - Yellow"));

    // Segmentos con caracteres prohibidos en sistemas de archivos
    QString invalid = "Track: Title / With \\ Slashes * And ? Quotes \" < > |";
    QString safe = Downloads::safeSegment(invalid);
    QVERIFY(!safe.contains('/'));
    QVERIFY(!safe.contains('\\'));
    QVERIFY(!safe.contains(':'));
    QVERIFY(!safe.contains('*'));
    QVERIFY(!safe.contains('?'));
    QVERIFY(!safe.contains('"'));
    QVERIFY(!safe.contains('<'));
    QVERIFY(!safe.contains('>'));
    QVERIFY(!safe.contains('|'));

    // Puntos y espacios al principio/final
    QCOMPARE(Downloads::safeSegment("...test..."), QString("test"));
    QCOMPARE(Downloads::safeSegment("   test   "), QString("test"));

    // Texto vacío cae a "descarga"
    QCOMPARE(Downloads::safeSegment(""), QString("descarga"));
    QCOMPARE(Downloads::safeSegment("   "), QString("descarga"));
    QCOMPARE(Downloads::safeSegment(":::"), QString("descarga"));

    // Caracteres unicode con tildes
    QString unicodeText = "Canción Épica (Año 2026)";
    QCOMPARE(Downloads::safeSegment(unicodeText), unicodeText);

    // Límite de longitud (recorte a <= 180 bytes)
    QString veryLong(200, 'A');
    QString safeLong = Downloads::safeSegment(veryLong);
    QVERIFY(safeLong.toUtf8().size() <= 180);
}

void TestLotusTune::testFriendlyError()
{
    // 404 / no existe
    QString err404 = Downloads::friendlyError("ERROR: [youtube] Video does not exist or was removed");
    QVERIFY(err404.contains("no existe") || err404.contains("privada"));

    // Contenido privado / login
    QString errPrivate = Downloads::friendlyError("ERROR: Sign in to confirm you’re not a bot / private video");
    QVERIFY(errPrivate.contains("privado") || errPrivate.contains("sesión"));

    // Fallo de red
    QString errNet = Downloads::friendlyError("ERROR: unable to download webpage: <urlopen error timed out>");
    QVERIFY(errNet.contains("red") || errNet.contains("conexión"));

    // Falta de espacio
    QString errDisk = Downloads::friendlyError("ERROR: [Errno 28] No space left on device");
    QVERIFY(errDisk.contains("espacio"));

    // Falta ffmpeg
    QString errFfmpeg = Downloads::friendlyError("ERROR: ffprobe or avprobe not found. Please install ffmpeg.");
    QVERIFY(errFfmpeg.contains("ffmpeg"));

    // Mensaje vacío
    QCOMPARE(Downloads::friendlyError(""), QString("La descarga falló."));
}

void TestLotusTune::testPartialFilesCleanup()
{
    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    const QString dirPath = tempDir.path();

    // Crear ficheros temporales y parciales
    QStringList partials = {
        dirPath + "/song.mp3.part",
        dirPath + "/song.mp3.ytdl",
        dirPath + "/audio.opus.temp",
        dirPath + "/track.m4a.tmp",
        dirPath + "/stream.temp-frag1"
    };

    for (const QString &p : partials) {
        QFile f(p);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("partial data");
        f.close();
        QVERIFY(QFile::exists(p));
    }

    // Crear un fichero de audio legítimo
    QString audioFile = dirPath + "/final_song.mp3";
    {
        QFile f(audioFile);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.write("audio data");
        f.close();
    }
    QVERIFY(QFile::exists(audioFile));

    // Limpiar parciales
    Downloads::removePartials(dirPath);

    // Comprobar que los parciales se eliminaron
    for (const QString &p : partials) {
        QVERIFY2(!QFile::exists(p), qPrintable(p + " no fue eliminado"));
    }

    // El fichero legítimo debe seguir existiendo
    QVERIFY(QFile::exists(audioFile));
}

void TestLotusTune::testCountAudioFiles()
{
    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());
    const QString dirPath = tempDir.path();

    QCOMPARE(Downloads::countAudioFiles(dirPath), 0);

    // Crear ficheros de varios tipos
    QStringList audios = {"track1.mp3", "track2.m4a", "track3.opus", "track4.flac"};
    for (const QString &a : audios) {
        QFile f(dirPath + "/" + a);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.close();
    }

    // Crear ficheros no de audio
    QStringList others = {"cover.jpg", "info.json", "notes.txt"};
    for (const QString &o : others) {
        QFile f(dirPath + "/" + o);
        QVERIFY(f.open(QIODevice::WriteOnly));
        f.close();
    }

    QCOMPARE(Downloads::countAudioFiles(dirPath), 4);
}

void TestLotusTune::testUniqueListFolder()
{
    QTemporaryDir tempDir;
    QVERIFY(tempDir.isValid());

    Downloads dl;
    dl.setFolder(tempDir.path());

    // Primera vez: nombre original
    QString f1 = dl.uniqueListFolder("Rock Clásico", "https://music.youtube.com/playlist?list=123");
    QCOMPARE(f1, QString("Rock Clásico"));

    // Simular que se crea la carpeta con metadatos
    QString fullPath = tempDir.path() + "/Rock Clásico";
    QDir().mkpath(fullPath);
    QFile metaFile(fullPath + "/.lotus-list.json");
    QVERIFY(metaFile.open(QIODevice::WriteOnly));
    metaFile.write("{\"url\":\"https://music.youtube.com/playlist?list=123\"}");
    metaFile.close();

    // Misma lista (misma URL): debe reutilizar la misma carpeta para reanudar
    QString fSame = dl.uniqueListFolder("Rock Clásico", "https://music.youtube.com/playlist?list=123");
    QCOMPARE(fSame, QString("Rock Clásico"));

    // Otra lista distinta con el mismo nombre (otra URL): debe asignar sufijo (2)
    QString fDifferent = dl.uniqueListFolder("Rock Clásico", "https://music.youtube.com/playlist?list=999");
    QCOMPARE(fDifferent, QString("Rock Clásico (2)"));
}

void TestLotusTune::testNormalizeUrl()
{
    // music.youtube.com a www.youtube.com
    QString musicUrl = "https://music.youtube.com/watch?v=dQw4w9WgXcQ";
    QCOMPARE(Player::normalizeUrl(musicUrl), QString("https://www.youtube.com/watch?v=dQw4w9WgXcQ"));

    // www.youtube.com intacta
    QString wwwUrl = "https://www.youtube.com/watch?v=dQw4w9WgXcQ";
    QCOMPARE(Player::normalizeUrl(wwwUrl), wwwUrl);

    // Fichero local intacto
    QString fileUrl = "file:///home/lots/music/song.opus";
    QCOMPARE(Player::normalizeUrl(fileUrl), fileUrl);

    // Vacío intacto
    QCOMPARE(Player::normalizeUrl(""), QString(""));
}

void TestLotusTune::testAppConfig()
{
    AppConfig cfg;
    cfg.set("test_key_1.0", "lotus_tune_ready");
    QCOMPARE(cfg.get("test_key_1.0"), QString("lotus_tune_ready"));
    QCOMPARE(cfg.get("non_existent_key_xyz"), QString(""));
}

QTEST_MAIN(TestLotusTune)
#include "test_all.moc"
