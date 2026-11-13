#pragma once

#include <QObject>
#include <QString>
#include <QStringList>

class QQmlEngine;
class QTranslator;

// Language of the interface.
//
// The strings in the source are Spanish, so "es" is always available and
// needs no file. The other languages come from the .qm files embedded under
// :/i18n (built from i18n/*.ts by tools/update-translations.sh). The choice
// lives in the app settings ("language": "system" or a code) and is applied
// at startup, before the QML is loaded, and again when it changes: the engine
// retranslates and every qsTr() binding is evaluated with the new language.
class Translator : public QObject
{
    Q_OBJECT
    // What the settings store: "system" or a language code.
    Q_PROPERTY(QString language READ language WRITE setLanguage NOTIFY languageChanged)
    // Codes that have a translation in this build (without the source one).
    Q_PROPERTY(QStringList available READ available CONSTANT)
    // The one in use after resolving "system".
    Q_PROPERTY(QString current READ current NOTIFY languageChanged)

public:
    explicit Translator(QQmlEngine *engine, QObject *parent = nullptr);

    QString language() const { return m_choice; }
    void setLanguage(const QString &choice);
    QStringList available() const;
    QString current() const { return m_current; }

    // Name of a language in its own words ("English", "español"), for the
    // picker in Ajustes.
    Q_INVOKABLE QString name(const QString &code) const;

signals:
    void languageChanged();

private:
    QString resolve(const QString &choice) const;
    void apply(const QString &code);

    QQmlEngine *m_engine = nullptr;
    QTranslator *m_tr = nullptr;
    QString m_choice = QStringLiteral("system");
    QString m_current;
};
