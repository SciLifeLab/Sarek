pipeline {
    agent any

    environment {
        JENKINS_API = credentials('api')
    }

    stages {
        stage('Setup environment') {
            steps {
                sh "docker pull maxulysse/sarek:dev"
            }
        }
        stage('Build') {
            steps {
              sh "./scripts/test.sh --profile kraken,docker --build"
            }
        }
        stage('Tests') {
            steps {
              sh "./scripts/test.sh --profile kraken,docker --test ALL"
            }
        }
    }

    post {
        failure {
            script {
                def response = sh(script: "curl -u ${JENKINS_API_USR}:${JENKINS_API_PSW} ${BUILD_URL}/consoleText", returnStdout: true).trim().replace('\n', '<br>')
                def comment = pullRequest.comment("##:rotating_light: Buil log output:<br><summary><details>${response}</details></summary>")
            }
        }
    }
}
