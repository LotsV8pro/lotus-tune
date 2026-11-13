#include "translator.h"

#include <QCoreApplication>
#include <QDir>
#include <QHash>
#include <QLocale>
#include <QQmlEngine>
#include <QSettings>
#include <QTranslator>

namespace {

// Where the compiled translations sit inside the binary.
const char *kPrefix = ":/i18n";

// Language of the source strings: no file needed.
const char *kSource = "es";

QSettings settings()
{
    return QSettings(QStringLiteral("lotus-tune"), QStringLiteral("lotus-tune"));
}

} // namespace

Translator::Translator(QQmlEngine *engine, QObject *parent)
    : QObject(parent)
    , m_engine(engine)
{
    m_choice = settings().value(QStringLiteral("language"),
                                QStringLiteral("system")).toString();
    if (m_choice.isEmpty())
        m_choice = QStringLiteral("system");
    apply(resolve(m_choice));
}

QStringList Translator::available() const
{
    QStringList codes;
    const QStringList files = QDir(QLatin1String(kPrefix))
                                  .entryList({QStringLiteral("lotus-tune_*.qm")},
                                             QDir::Files, QDir::Name);
    for (const QString &f : files) {
        QString code = f.mid(11);          // "lotus-tune_" is 11 chars
        code.chop(3);                      // ".qm"
        if (!code.isEmpty() && !codes.contains(code))
            codes << code;
    }
    return codes;
}

QString Translator::name(const QString &code) const
{
    // The language in its own words, without a territory. QLocale("es")
    // resolves to es_ES and answers "español de España"; QLocale("en")
    // answers "American English". A list of languages shows "español" and
    // "English", so the common ones are written out and the rest fall back
    // to whatever Qt knows.
    static const QHash<QString, QString> names = {
        {QStringLiteral("es"), QStringLiteral("español")},
        {QStringLiteral("en"), QStringLiteral("English")},
        {QStringLiteral("fr"), QStringLiteral("français")},
        {QStringLiteral("pt"), QStringLiteral("português")},
        {QStringLiteral("de"), QStringLiteral("Deutsch")},
        {QStringLiteral("it"), QStringLiteral("italiano")},
        {QStringLiteral("ca"), QStringLiteral("català")},
        {QStringLiteral("gl"), QStringLiteral("galego")},
        {QStringLiteral("eu"), QStringLiteral("euskara")},
        {QStringLiteral("ru"), QStringLiteral("русский")},
        {QStringLiteral("ja"), QStringLiteral("日本語")},
        {QStringLiteral("ko"), QStringLiteral("한국어")},
        {QStringLiteral("zh"), QStringLiteral("中文")},
        {QStringLiteral("ar"), QStringLiteral("العربية")},
    };
    const auto it = names.constFind(code);
    if (it != names.constEnd())
        return it.value();
    return QLocale(code).nativeLanguageName();
}

QString Translator::resolve(const QString &choice) const
{
    const QStringList codes = available();
    if (choice != QLatin1String("system") && !choice.isEmpty()) {
        // A language that is no longer in the build: fall back to the system
        // instead of leaving the interface in the source language.
        if (codes.contains(choice) || choice == QLatin1String(kSource))
            return choice;
    }
    const QStringList ui = QLocale::system().uiLanguages();
    for (const QString &tag : ui) {
        const QString base = tag.section(QLatin1Char('-'), 0, 0);
        if (base == QLatin1String(kSource) || codes.contains(base))
            return base;
    }
    if (codes.contains(QStringLiteral("en")))
        return QStringLiteral("en");
    return QString::fromLatin1(kSource);
}

void Translator::setLanguage(const QString &choice)
{
    const QString clean = choice.trimmed().isEmpty() ? QStringLiteral("system")
                                                     : choice.trimmed();
    if (clean == m_choice)
        return;
    m_choice = clean;
    settings().setValue(QStringLiteral("language"), m_choice);
    const QString code = resolve(m_choice);
    // The window title and the stuff outside QML read this too.
    QLocale::setDefault(QLocale(code));
    apply(code);
    if (m_engine)
        m_engine->retranslate();
    emit languageChanged();
}

void Translator::apply(const QString &code)
{
    if (m_tr) {
        QCoreApplication::removeTranslator(m_tr);
        delete m_tr;
        m_tr = nullptr;
    }
    m_current = code;
    // Every language with a .qm is loaded, including the source one: the
    // Spanish file carries nothing but the plural forms, which Qt cannot
    // build from the source strings (%n would print the bare number).
    {
        auto *tr = new QTranslator(this);
        if (tr->load(QStringLiteral("lotus-tune_") + code, QLatin1String(kPrefix))) {
            QCoreApplication::installTranslator(tr);
            m_tr = tr;
            qInfo() << "[i18n] language" << code << "loaded";
        } else {
            delete tr;
            qInfo() << "[i18n] language" << code << "built in";
        }
    }
    QLocale::setDefault(QLocale(code));
}
