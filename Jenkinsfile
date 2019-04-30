pipeline {
    agent any

    environment {
        JENKINS_API = credentials('api')
    }

    stages {
        stage('Setup environment') {
            steps {
                sh "docker pull maxulysse/sarek:dev"
                sh "docker pull maxulysse/snpeffgrch37:dev"
                sh "docker pull maxulysse/vepgrch37:dev"
            }
        }
        stage('Build') {
            steps {
              sh "./scripts/test.sh --profile kraken --build"
            }
        }
        stage('MULTIPLE') {
            steps {
                sh "./scripts/test.sh --profile kraken --test MULTIPLE"
            }
        }
        stage('SOMATIC') {
            steps {
              sh "./scripts/test.sh --profile kraken --test SOMATIC"
            }
        }
        stage('GERMLINE') {
            steps {
              sh "./scripts/test.sh --profile kraken --test GERMLINE"
            }
        }
        stage('TARGETED') {
            steps {
              sh "./scripts/test.sh --profile kraken --test TARGETED"
            }
        }
        stage('ANNOTATEALL') {
            steps {
              sh "./scripts/test.sh --profile kraken --test ANNOTATEALL"
            }
        }
    }

    post {
        failure {
            script {
                def response = sh(script: "curl -u ${JENKINS_API_USR}:${JENKINS_API_PSW} ${BUILD_URL}/consoleText", returnStdout: true).trim().replace('\n', '<br>')
                def comment = pullRequest.comment("## :rotating_light: Buil log output:<br><summary><details>${response}</details></summary>")
            }
        }
    }
}
